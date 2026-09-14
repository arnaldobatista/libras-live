import AppKit
import AudioCapture
import AVFoundation
import Foundation
import LibrasCore
import Observation
import os
import OverlayServer
import Transcription

/// Linha do monitor: uma frase e o que aconteceu com ela.
struct FeedEntry: Identifiable, Equatable {
    enum Status: Equatable {
        case translating, queued, playing, played, dropped
    }

    let id: Int
    let date: Date
    let text: String
    /// Glosa devolvida pelo tradutor.
    var gloss: String?
    /// O que foi realmente sinalizado depois da otimização.
    var signed: String?
    var source: GlossSource?
    var status: Status
    var speed: Double?
    /// Quantas frases foram juntas no mesmo envio (1 = sozinha).
    var batchSize = 1
    var dropReason: String?
    var removed: [String] = []
    var replaced: [String] = []
}

/// Estado do app e orquestração: captura → fala → trechos → glosa → dicionário → fila → overlay.
@MainActor
@Observable
final class AppModel {
    // MARK: Estado publicado

    var settings: AppSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    private(set) var devices: [AudioDevice] = []
    private(set) var level: AudioLevel = .silence
    /// Pico por canal do dispositivo (0…1), atualizado enquanto monitora.
    private(set) var channelPeaks: [Float] = []
    private(set) var isCapturing = false
    private(set) var isListening = false
    private(set) var isStartingListening = false
    var isMonitoring = false {
        didSet {
            guard isMonitoring != oldValue else { return }
            updateCapture()
            updateScanner()
        }
    }

    private(set) var microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    /// Primeira vez que o app abre nesta máquina (sem preferências salvas).
    let isFirstRun: Bool

    private(set) var serverRunning = false
    private(set) var roster = OverlayRoster()
    var overlayClients: Int { roster.total }
    var overlayReady: Int { roster.readyCount }
    var overlayHidden: Int { roster.hiddenCount }

    private(set) var partialText = ""
    /// Detector de voz: há fala no canal agora.
    private(set) var voiceDetected = false
    private(set) var feed: [FeedEntry] = []
    private(set) var snapshot = SchedulerSnapshot()
    private(set) var glossCacheCount = 0
    private(set) var signStats = SignCache.Stats()

    private(set) var errorMessage: String?
    private(set) var captureWarning: String?
    /// Aviso sobre a logo (ex.: imagem com fundo).
    private(set) var appearanceWarning: String?
    /// Muda quando a logo renderizada muda (atualiza a miniatura).
    private(set) var logoVersion = 0

    let sessionLog = SessionLog()
    private(set) var logEventCount = 0

    var selectedDevice: AudioDevice? {
        devices.first { $0.uid == settings.deviceUID }
    }

    /// Porta em uso: a salva nas preferências, ou `LIBRAS_PORT` quando definida.
    var port: Int { AppPaths.portOverride ?? settings.port }

    var overlayURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    // MARK: Componentes

    private let log = Logger(subsystem: "LibrasLive", category: "app")
    private var server: OverlayServer?
    private var serverEventsTask: Task<Void, Never>?
    private let glossService = GlossService(cacheURL: AppPaths.glossCache)
    private var scheduler: SignScheduler
    private var segmenter: Segmenter
    /// Decide quando a fala vira trecho: frase estável, prefixo estável, pausa real (silêncio) ou final.
    private var speech: SpeechCommitController
    private var lastPartialLogged = Date.distantPast
    private var loggedMissingSigns = Set<String>()

    private var capture: ChannelCapture?
    private var scanner: ChannelScanner?
    private var engine: AppleSpeechEngine?
    private var engineEventsTask: Task<Void, Never>?
    private var deviceObserver: AudioDeviceObserver?
    private var ticker: Timer?
    private var lastCaptionSent = Date.distantPast
    private var lastSettingsLogged = Date.distantPast

    // Aparência: cada mudança ganha uma revisão; o overlay só aplica (ou recarrega) quando ela muda.
    private var appearanceRevision = 1
    private var appearanceReload = false
    private var appearanceTask: Task<Void, Never>?

    /// Mensagens para os overlays, enviadas uma a uma e na ordem em que foram geradas.
    private let outbox: AsyncStream<OverlayOutbound>.Continuation
    private var outboxTask: Task<Void, Never>?

    /// Repassa buffers da thread de áudio para o motor atual sem tocar no MainActor.
    private let engineSink = OSAllocatedUnfairLock<AppleSpeechEngine?>(initialState: nil)

    init() {
        isFirstRun = !AppSettings.hasStoredSettings()
        let settings = AppSettings.load()
        self.settings = settings
        scheduler = SignScheduler(policy: settings.policy, glossOptions: settings.glossOptions)
        segmenter = Segmenter(maxWords: settings.maxWords)
        speech = SpeechCommitController(
            committer: TranscriptCommitter(commaMinWords: settings.commitOnComma ? 6 : 0),
            pauseRule: PauseCommitRule(silenceSeconds: settings.pauseCommitSeconds)
        )
        sessionLog.isEnabled = settings.logEnabled

        let (stream, continuation) = AsyncStream<OverlayOutbound>.makeStream(bufferingPolicy: .bufferingNewest(256))
        outbox = continuation
        outboxTask = Task { [weak self] in
            for await message in stream {
                guard let server = self?.server else { continue }
                await server.send(message)
            }
        }
    }

    private func send(_ message: OverlayOutbound) {
        outbox.yield(message)
    }

    private func record(_ event: String, _ fields: [String: Any] = [:]) {
        sessionLog.record(event, fields)
        logEventCount = sessionLog.eventCount
    }

    // MARK: Ciclo de vida

    func bootstrap() {
        refreshDevices()
        deviceObserver = AudioDeviceObserver { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }

        // Só escolhe um padrão na primeira execução. Se o dispositivo salvo (ex.: a mesa)
        // estiver desligado agora, mantém a escolha e espera ele reconectar.
        if settings.deviceUID == nil {
            settings.deviceUID = AudioDevices.defaultInputDevice()?.uid ?? devices.first?.uid
        }

        // Uma tela pode ter pedido monitoramento antes da lista de dispositivos existir.
        if isMonitoring {
            captureWarning = nil
            updateCapture()
            updateScanner()
        }

        record("session.start", [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "device": selectedDevice?.name ?? "—",
            "channels": settings.channels.map { $0 + 1 },
            "settings": settings.logSummary,
        ])

        Task {
            await glossService.load()
            glossCacheCount = await glossService.count
        }
        Task {
            await SessionLog.pruneIdleSessions(keeping: sessionLog.fileURL)
            refreshLogs()
        }

        startServer()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func shutdown() async {
        ticker?.invalidate()
        scanner?.stop()
        await stopListening()
        capture?.stop()
        await glossService.save()
        await server?.stop()
    }

    // MARK: Servidor

    private func startServer() {
        guard let overlayDirectory = AppPaths.overlayDirectory() else {
            errorMessage = "Pasta do overlay não encontrada. Rode Scripts/fetch-vlibras.sh."
            return
        }

        prepareAppearanceFiles()
        let server = OverlayServer(configuration: OverlayServerConfiguration(
            port: port,
            overlayDirectory: overlayDirectory,
            signCacheDirectory: AppPaths.signCache,
            appearanceDirectory: AppPaths.appearance
        ))
        self.server = server

        server.setStatusProvider { @MainActor [weak self] in
            self?.statusJSON() ?? Data("{}".utf8)
        }

        serverEventsTask = Task { [weak self] in
            for await event in server.events {
                self?.handle(event)
            }
        }

        server.start()
        pushOverlayConfig()
    }

    private func restartServer() {
        let old = server
        serverEventsTask?.cancel()
        server = nil
        serverRunning = false
        roster = OverlayRoster()
        scheduler.resetPlaying()
        Task {
            await old?.stop()
            self.startServer()
        }
    }

    private func handle(_ event: OverlayServerEvent) {
        switch event {
        case let .running(port):
            serverRunning = true
            log.info("Overlay em http://127.0.0.1:\(port)")
        case let .failed(message):
            serverRunning = false
            errorMessage = "Servidor do overlay: \(message)"
            record("error", ["message": "Servidor do overlay: \(message)"])
        case let .clientConnected(id):
            roster.connect(id)
            record("overlay", ["state": "conectado (\(roster.total))"])
        case let .clientDisconnected(id):
            if roster.disconnect(id) { finishPlaying(reason: "overlay desconectou") }
            if !roster.canPlay { releasePlaying() }
            record("overlay", ["state": "desconectado (\(roster.total))"])
            pump()
        case let .inbound(message, client):
            handleOverlay(message, from: client)
        case let .say(text):
            submitFinal(text, source: "api")
        case .clearRequested:
            clearQueue()
        case let .appearance(patch):
            settings.appearance = patch.applied(to: settings.appearance)
        }
    }

    private func handleOverlay(_ message: OverlayInbound, from client: UUID) {
        switch message.type {
        case .hello, .ready, .visibility:
            let wasHidden = roster.hiddenCount
            if roster.apply(message, from: client) { finishPlaying(reason: "overlay oculto") }
            if message.type == .ready { record("overlay", ["state": "pronto"]) }
            if roster.hiddenCount != wasHidden { record("overlay", ["state": "ocultos: \(roster.hiddenCount)"]) }
            pump()
        case .playing:
            if let id = message.id, id == scheduler.playing?.id {
                for itemID in scheduler.playing?.itemIDs ?? [] { updateFeed(itemID) { $0.status = .playing } }
            }
        case .ended:
            guard let id = message.id else { return }
            if roster.ended(itemID: id, from: client) { finishPlaying(reason: message.reason ?? "done") }
            pump()
        case .error:
            errorMessage = "Overlay: \(message.message ?? "erro desconhecido")"
            record("error", ["message": errorMessage ?? ""])
        case .progress, .avatar:
            break
        }
    }

    /// Todos os overlays aguardados terminaram o envio atual.
    private func finishPlaying(reason: String) {
        guard let batch = scheduler.playing, let finished = scheduler.markEnded(id: batch.id) else { return }
        for itemID in finished.itemIDs { updateFeed(itemID) { $0.status = .played } }
        record("ended", ["id": finished.id, "reason": reason, "duration": Date().timeIntervalSince(finished.startedAt)])
    }

    /// Sem overlay pronto: esquece o envio em andamento para não travar a fila.
    private func releasePlaying() {
        roster.cancelPlayback()
        if let batch = scheduler.resetPlaying() {
            for itemID in batch.itemIDs { updateFeed(itemID) { $0.status = .played } }
            record("ended", ["id": batch.id, "reason": "sem overlay", "duration": Date().timeIntervalSince(batch.startedAt)])
        }
    }

    private func pushOverlayConfig() {
        guard let server else { return }
        let appearance = settings.appearance
        let config = OverlayConfig(
            avatar: settings.avatar.rawValue,
            subtitles: settings.subtitles,
            speed: settings.policy.baseSpeed,
            signsBaseUrl: settings.useSignCache ? server.signsBaseURL : SignCache.defaultUpstream.absoluteString,
            appearance: appearance.enabled ? appearance.personalizationJSON(logoURL: logoURL(for: appearance)) : "",
            appearanceRevision: appearanceRevision,
            appearanceReload: appearanceReload
        )
        send(.config(config))
    }

    // MARK: Dispositivos e captura

    func refreshDevices() {
        devices = AudioDevices.inputDevices()
    }

    private func devicesChanged() {
        let previous = selectedDevice
        refreshDevices()
        let current = selectedDevice

        if previous?.id != current?.id || previous?.inputChannels != current?.inputChannels {
            // Dispositivo voltou (ex.: mesa religada): retoma a captura se ela deveria estar ativa.
            if capture != nil { restartCapture() } else { updateCapture() }
            restartScanner()
        }
    }

    func toggleChannel(_ index: Int) {
        var channels = Set(settings.channels)
        if channels.contains(index) { channels.remove(index) } else { channels.insert(index) }
        settings.channels = channels.sorted()
    }

    func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.microphoneAuthorized = granted
                self.updateCapture()
                self.updateScanner()
            }
        }
    }

    /// Captura fica ligada enquanto estiver ouvindo ou monitorando o canal.
    private func updateCapture() {
        let shouldCapture = isListening || isStartingListening || isMonitoring
        if shouldCapture, capture == nil {
            startCapture()
        } else if !shouldCapture, capture != nil {
            stopCapture()
        }
    }

    private func restartCapture() {
        guard capture != nil else { return }
        stopCapture()
        startCapture()
    }

    private func startCapture() {
        captureWarning = nil

        guard AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined else {
            requestMicrophoneAccess()
            return
        }
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard microphoneAuthorized else {
            setCaptureWarning("Sem permissão de microfone. Libere em Ajustes do Sistema › Privacidade › Microfone.")
            return
        }
        guard let device = selectedDevice else {
            setCaptureWarning(settings.deviceUID == nil
                ? "Nenhum dispositivo de áudio selecionado."
                : "Dispositivo desconectado. A captura volta sozinha quando ele reconectar.")
            return
        }

        let validChannels = settings.channels.filter { $0 < device.inputChannels }
        let capture = ChannelCapture(device: device, channels: validChannels, gain: settings.gainLinear)
        let sink = engineSink

        do {
            try capture.start(
                onBuffer: { buffer in
                    sink.withLock { $0 }?.append(buffer)
                },
                onLevel: { [weak self] level in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.level = level
                        self.speech.level(AudioLevel.decibels(level.rms), at: Date())
                    }
                },
                onInterruption: { [weak self] message in
                    Task { @MainActor in
                        self?.setCaptureWarning(message)
                        self?.refreshDevices()
                        self?.restartCapture()
                    }
                }
            )
            self.capture = capture
            isCapturing = true
        } catch {
            setCaptureWarning(error.localizedDescription)
            isCapturing = false
        }
    }

    private func setCaptureWarning(_ message: String) {
        captureWarning = message
        record("warning", ["message": message])
    }

    /// Medidores por canal: só enquanto o usuário está monitorando.
    private func updateScanner() {
        if isMonitoring, scanner == nil, microphoneAuthorized, let device = selectedDevice {
            let scanner = ChannelScanner(device: device)
            do {
                try scanner.start { [weak self] peaks in
                    DispatchQueue.main.async { self?.channelPeaks = peaks }
                }
                self.scanner = scanner
            } catch {
                setCaptureWarning(error.localizedDescription)
            }
        } else if !isMonitoring, let scanner {
            scanner.stop()
            self.scanner = nil
            channelPeaks = []
        }
    }

    private func restartScanner() {
        scanner?.stop()
        scanner = nil
        channelPeaks = []
        updateScanner()
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        isCapturing = false
        level = .silence
    }

    // MARK: Reconhecimento

    func toggleListening() {
        Task {
            if isListening || isStartingListening { await stopListening() } else { await startListening() }
        }
    }

    func startListening() async {
        guard !isListening, !isStartingListening else { return }
        errorMessage = nil
        isStartingListening = true
        updateCapture()

        let engine = AppleSpeechEngine(locale: Locale(identifier: "pt-BR"))
        do {
            try await engine.start()
        } catch {
            isStartingListening = false
            errorMessage = error.localizedDescription
            record("error", ["message": error.localizedDescription])
            updateCapture()
            return
        }

        self.engine = engine
        engineSink.withLock { $0 = engine }
        engineEventsTask = Task { [weak self] in
            for await event in engine.events {
                guard !Task.isCancelled else { break }
                self?.handle(event)
            }
        }

        isStartingListening = false
        isListening = true
        if capture == nil { startCapture() }
        record("listen.start", [
            "device": selectedDevice?.name ?? "—",
            "channels": settings.channels.map { $0 + 1 },
            "settings": settings.logSummary,
        ])
    }

    func stopListening() async {
        guard isListening || engine != nil else { return }
        isListening = false
        engineSink.withLock { $0 = nil }
        engineEventsTask?.cancel()
        engineEventsTask = nil

        let engine = self.engine
        self.engine = nil
        await engine?.stop()

        // O que ainda estava provisório também vai para a fila.
        submit(speech.stop())
        partialText = ""
        voiceDetected = false
        updateCapture()
        record("listen.stop")
    }

    private func handle(_ event: TranscriptEvent) {
        let now = Date()
        switch event {
        case let .partial(text):
            // Hipótese do reconhecedor no log (no máximo 2 por segundo), para medir ritmo e latência.
            if now.timeIntervalSince(lastPartialLogged) >= 0.5 {
                lastPartialLogged = now
                record("partial", ["text": text])
            }
            submit(speech.partial(text, at: now))
            partialText = speech.pendingText
            sendCaption(text, final: false)
        case let .final(text):
            submit(speech.final(text))
            partialText = ""
            sendCaption(text, final: true)
        case let .failure(message):
            log.error("Reconhecedor falhou: \(message, privacy: .public). Reiniciando.")
            errorMessage = "Reconhecimento reiniciado: \(message)"
            record("error", ["message": "Reconhecedor falhou: \(message)"])
            Task {
                await stopListening()
                await startListening()
            }
        }
    }

    private func submit(_ commits: [SpeechCommitController.Commit]) {
        for commit in commits {
            var extra: [String: Any] = [:]
            if commit.source == .silence || commit.source == .stalled {
                extra = ["silence": commit.silence, "unchanged": commit.unchanged]
            }
            submitFinal(commit.text, source: commit.source.rawValue, extra: extra)
        }
    }

    private func sendCaption(_ text: String, final: Bool) {
        let now = Date()
        guard final || now.timeIntervalSince(lastCaptionSent) > 0.2 else { return }
        lastCaptionSent = now
        send(.caption(text: text, final: final))
    }

    // MARK: Fila

    /// Texto (do reconhecedor, digitado ou da API) entra na fila já quebrado em trechos.
    func submitFinal(_ text: String, source: String = "digitado", extra: [String: Any] = [:]) {
        record("commit", extra.merging(["text": text, "source": source]) { _, new in new })

        for segment in segmenter.split(text) {
            let item = scheduler.enqueue(text: segment)
            appendFeed(FeedEntry(id: item.id, date: item.createdAt, text: segment, status: .translating))
            record("enqueue", ["id": item.id, "text": segment])

            Task {
                let result = await glossService.translate(segment)
                var fields: [String: Any] = ["id": item.id, "gloss": result.gloss, "source": result.source.rawValue, "ms": result.duration * 1000]
                if let error = result.error { fields["error"] = error }
                record("gloss", fields)
                if result.source == .remote { glossCacheCount = await glossService.count }

                // Sem tradução: descarta artigos e preposições, que seriam soletrados.
                let tokens = result.source == .fallback
                    ? GlossOptimizer.fallbackTokens(for: segment)
                    : result.gloss.split(separator: " ").map(String.init)
                let availability = await resolveAvailability(tokens)

                scheduler.setGloss(id: item.id, tokens: tokens, availability: availability, usedFallback: result.source == .fallback)
                record("ready", ["id": item.id, "ms": Date().timeIntervalSince(item.createdAt) * 1000])
                updateFeed(item.id) {
                    $0.gloss = result.gloss
                    $0.source = result.source
                    if $0.status == .translating { $0.status = .queued }
                }
                pump()
            }
        }
        pump()
    }

    /// Consulta o dicionário de sinais (baixa o que falta) para evitar soletração.
    /// Nunca segura a frase por mais de 2 s: no prazo, segue com o que já se sabe e os downloads
    /// continuam em segundo plano (aquecem o cache para a próxima vez).
    private func resolveAvailability(_ tokens: [String]) async -> [String: Bool] {
        guard settings.useSignCache, settings.prefetchSigns, let server else { return [:] }
        let cache = server.signCache
        let known = OSAllocatedUnfairLock(initialState: [String: Bool]())
        let finished = OSAllocatedUnfairLock(initialState: false)

        let availability: [String: Bool] = await withCheckedContinuation { continuation in
            @Sendable func finish() {
                let first = finished.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: known.withLock { $0 }) }
            }
            Task.detached {
                let direct = await cache.availability(for: tokens)
                known.withLock { $0.merge(direct) { current, _ in current } }
                let alternatives = GlossOptimizer.lookupNames(for: tokens, availability: direct)
                if !alternatives.isEmpty {
                    let extra = await cache.availability(for: alternatives)
                    known.withLock { $0.merge(extra) { current, _ in current } }
                }
                finish()
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                finish()
            }
        }

        for token in tokens where availability[token] == false && !loggedMissingSigns.contains(token) {
            loggedMissingSigns.insert(token)
            record("sign.missing", ["name": token])
        }
        return availability
    }

    func clearQueue() {
        for item in scheduler.queue { updateFeed(item.id) { $0.status = .dropped; $0.dropReason = "fila limpa" } }
        if let batch = scheduler.playing {
            for itemID in batch.itemIDs { updateFeed(itemID) { $0.status = .played } }
        }
        roster.cancelPlayback()
        let removed = scheduler.clear()
        record("clear", ["count": removed.count])
        send(.stop)
        refreshSnapshot()
    }

    private func pump() {
        guard server != nil else { return }
        let now = Date()
        let step = scheduler.next(at: now, overlayReady: roster.canPlay)

        for drop in step.dropped {
            updateFeed(drop.item.id) {
                $0.status = .dropped
                $0.dropReason = drop.reason.rawValue
            }
            record("drop", ["id": drop.item.id, "text": drop.item.text, "reason": drop.reason.rawValue, "age": drop.age])
        }

        if let dispatch = step.dispatch {
            roster.beginPlayback(itemID: dispatch.id)
            for part in dispatch.parts {
                let optimization = part.optimization
                updateFeed(part.item.id) {
                    $0.status = .playing
                    $0.speed = dispatch.speed
                    $0.signed = optimization.gloss
                    $0.batchSize = dispatch.parts.count
                    $0.removed = optimization.removed
                    $0.replaced = optimization.replaced
                }
                if !optimization.removed.isEmpty || !optimization.replaced.isEmpty {
                    record("optimize", [
                        "id": part.item.id,
                        "gloss": optimization.gloss,
                        "removed": optimization.removed,
                        "replaced": optimization.replaced,
                        "spelled": optimization.spelled,
                    ])
                }
            }
            record("dispatch", [
                "id": dispatch.id,
                "ids": dispatch.itemIDs,
                "gloss": dispatch.gloss,
                "speed": dispatch.speed,
                "lag": dispatch.lag,
                "estimate": dispatch.estimatedDuration,
                "queued": scheduler.queue.count,
            ])
            send(.gloss(id: dispatch.id, gloss: dispatch.gloss, text: dispatch.text, speed: dispatch.speed))
        }
        refreshSnapshot()
    }

    private func tick() {
        let now = Date()
        if let expired = scheduler.expireIfNeeded(at: now) {
            roster.cancelPlayback()
            for itemID in expired.itemIDs { updateFeed(itemID) { $0.status = .played } }
            record("ended", ["id": expired.id, "reason": "prazo esgotado", "duration": now.timeIntervalSince(expired.startedAt)])
        }
        if isListening {
            submit(speech.tick(at: now))
            partialText = speech.pendingText
            let speaking = speech.vad.lastSpeechAt.map { now.timeIntervalSince($0) < 0.3 } ?? false
            if speaking != voiceDetected { voiceDetected = speaking }
        }
        pump()
        if let server {
            Task {
                let stats = await server.signCache.stats
                if stats != signStats { signStats = stats }
            }
        }
    }

    private func refreshSnapshot() {
        let next = scheduler.snapshot()
        if next != snapshot { snapshot = next }
    }

    // MARK: Monitor

    private func appendFeed(_ entry: FeedEntry) {
        feed.insert(entry, at: 0)
        if feed.count > 200 { feed.removeLast(feed.count - 200) }
    }

    private func updateFeed(_ id: Int, _ change: (inout FeedEntry) -> Void) {
        guard let index = feed.firstIndex(where: { $0.id == id }) else { return }
        change(&feed[index])
    }

    func dismissError() {
        errorMessage = nil
    }

    func copyOverlayURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(overlayURL.absoluteString, forType: .string)
    }

    func openOverlayInBrowser(debug: Bool = true) {
        var components = URLComponents(url: overlayURL, resolvingAgainstBaseURL: false)!
        if debug { components.queryItems = [URLQueryItem(name: "debug", value: "1")] }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func clearSignCache() {
        guard let server else { return }
        Task {
            await server.signCache.clear()
            signStats = await server.signCache.stats
        }
    }

    // MARK: Aparência do avatar

    /// URL da logo para o JSON. O player só aceita logos cuja URL contenha `vlibras.gov.br`;
    /// o parâmetro no fim atende a essa verificação sem sair do servidor local.
    private func logoURL(for appearance: AvatarAppearance) -> String {
        switch appearance.logoMode {
        case .vlibras:
            return ""
        case .none:
            return "http://127.0.0.1:\(port)/appearance/blank.png?v=1&vlibras.gov.br"
        case .custom:
            guard FileManager.default.fileExists(atPath: AppPaths.appearance.appendingPathComponent("logo.png").path) else { return "" }
            return "http://127.0.0.1:\(port)/appearance/logo.png?v=\(logoVersion)&vlibras.gov.br"
        }
    }

    /// Garante `blank.png` e renderiza a logo salva ao abrir o app.
    private func prepareAppearanceFiles() {
        let directory = AppPaths.appearance
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blank = directory.appendingPathComponent("blank.png")
        if !FileManager.default.fileExists(atPath: blank.path) {
            try? LogoRenderer.blankPNG().write(to: blank)
        }
        renderLogoIfNeeded(settings.appearance)
    }

    @discardableResult
    private func renderLogoIfNeeded(_ appearance: AvatarAppearance) -> Bool {
        guard let file = appearance.logoSourceFile else { return false }
        let source = AppPaths.appearance.appendingPathComponent(file)
        do {
            let output = try LogoRenderer.render(sourceURL: source, scale: appearance.logoScale, offsetX: appearance.logoOffsetX, offsetY: appearance.logoOffsetY)
            try output.png.write(to: AppPaths.appearance.appendingPathComponent("logo.png"), options: .atomic)
            logoVersion += 1
            appearanceWarning = output.hasOpaqueBackground
                ? "A logo parece ter fundo. Use PNG com fundo transparente para não aparecer um quadrado na camisa."
                : nil
            return true
        } catch {
            appearanceWarning = error.localizedDescription
            return false
        }
    }

    /// Mudanças de cor chegam várias por segundo (seletor de cor): aplica no máximo a cada 0,25 s.
    private func scheduleAppearanceUpdate(from old: AvatarAppearance) {
        let logoChanged = settings.appearance.logoSourceFile != old.logoSourceFile
            || settings.appearance.logoScale != old.logoScale
            || settings.appearance.logoOffsetX != old.logoOffsetX
            || settings.appearance.logoOffsetY != old.logoOffsetY
        let reload = settings.appearance.needsReload(comparedTo: old)

        appearanceTask?.cancel()
        appearanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            if logoChanged { self.renderLogoIfNeeded(self.settings.appearance) }
            self.appearanceRevision += 1
            self.appearanceReload = reload
            self.pushOverlayConfig()
            self.record("appearance", [
                "enabled": self.settings.appearance.enabled,
                "logo": self.settings.appearance.logoMode.rawValue,
                "position": self.settings.appearance.logoPosition.rawValue,
                "reload": reload,
            ])
        }
    }

    /// Escolhe uma imagem, guarda uma cópia e passa a usar como logo.
    func chooseLogo() {
        let panel = NSOpenPanel()
        panel.title = "Escolher logo"
        panel.message = "PNG com fundo transparente fica melhor. A imagem é ajustada ao quadro de 500 × 500."
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .svg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLogo(from: url)
    }

    /// Copia a imagem para a pasta de aparência e passa a usar como logo (escolha ou arrastar e soltar).
    func importLogo(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let directory = AppPaths.appearance
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "logo-original-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension.lowercased())"
        do {
            if let previous = settings.appearance.logoSourceFile {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous))
            }
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(fileName))
            settings.appearance.logoSourceFile = fileName
            settings.appearance.logoMode = .custom
            settings.appearance.enabled = true
        } catch {
            appearanceWarning = "Não foi possível copiar a logo: \(error.localizedDescription)"
        }
    }

    func resetAppearanceColors() {
        let defaults = AvatarAppearance.vlibrasColors
        settings.appearance.hair = defaults.hair
        settings.appearance.eyebrows = defaults.eyebrows
        settings.appearance.skin = defaults.skin
        settings.appearance.iris = defaults.iris
        settings.appearance.eyes = defaults.eyes
        settings.appearance.shirt = defaults.shirt
        settings.appearance.pants = defaults.pants
    }

    /// URL da prévia dentro do app (não conta como overlay visível para a fila).
    var previewURL: URL {
        URL(string: "http://127.0.0.1:\(port)/?preview=1")!
    }

    var logoPreviewURL: URL? {
        let url = AppPaths.appearance.appendingPathComponent("logo.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Sessões de log

    struct SessionLogFile: Identifiable, Hashable {
        let url: URL
        let date: Date
        let size: Int64
        var id: URL { url }
        var isCurrent: Bool
    }

    /// Resumo da sessão atual (calculado sob demanda).
    private(set) var currentSummary: SessionLogFormatter.Summary?
    private(set) var sessionFiles: [SessionLogFile] = []

    func refreshLogs() {
        let current = sessionLog.fileURL
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: SessionLog.directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []
        sessionFiles = urls
            .filter { $0.pathExtension == "jsonl" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return SessionLogFile(
                    url: url,
                    date: values?.contentModificationDate ?? .distantPast,
                    size: Int64(values?.fileSize ?? 0),
                    isCurrent: url.standardizedFileURL == current.standardizedFileURL
                )
            }
            .sorted { $0.date > $1.date }

        Task {
            let contents = await sessionLog.currentContents()
            currentSummary = SessionLogFormatter.summarize(SessionLogFormatter.parse(contents))
        }
    }

    /// Exporta uma sessão anterior (.txt legível + .jsonl).
    func exportLog(file: SessionLogFile) {
        let panel = NSSavePanel()
        panel.title = "Salvar log da sessão"
        panel.nameFieldStringValue = file.url.deletingPathExtension().lastPathComponent + ".txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let contents = try String(contentsOf: file.url, encoding: .utf8)
            try SessionLogFormatter.format(contents).write(to: destination, atomically: true, encoding: .utf8)
            try contents.write(to: destination.deletingPathExtension().appendingPathExtension("jsonl"), atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            errorMessage = "Não foi possível salvar o log: \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: OBS

    enum OverlayBackground: String, CaseIterable, Identifiable {
        case transparent, green, blue

        var id: String { rawValue }
        var title: String {
            switch self {
            case .transparent: "Transparente"
            case .green: "Verde (chroma key)"
            case .blue: "Azul (chroma key)"
            }
        }
        var parameter: String? {
            switch self {
            case .transparent: nil
            case .green: "00b140"
            case .blue: "0047bb"
            }
        }
    }

    func overlayURL(background: OverlayBackground, debug: Bool) -> URL {
        var components = URLComponents(url: overlayURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let color = background.parameter { items.append(URLQueryItem(name: "bg", value: color)) }
        if debug { items.append(URLQueryItem(name: "debug", value: "1")) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? overlayURL
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func restoreTranslationDefaults() {
        let defaults = AppSettings()
        settings.policy = defaults.policy
        settings.maxWords = defaults.maxWords
        settings.unknownWords = defaults.unknownWords
        settings.removePauses = defaults.removePauses
        settings.pauseCommitSeconds = defaults.pauseCommitSeconds
        settings.commitOnComma = defaults.commitOnComma
        settings.useSignCache = defaults.useSignCache
        settings.prefetchSigns = defaults.prefetchSigns
    }

    // MARK: Logs

    /// Pergunta onde salvar e grava `.txt` (legível) + `.jsonl` (dados completos).
    func exportLog() {
        let panel = NSSavePanel()
        panel.title = "Salvar log da sessão"
        panel.nameFieldStringValue = sessionLog.fileURL.deletingPathExtension().lastPathComponent + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await sessionLog.export(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = "Não foi possível salvar o log: \(error.localizedDescription)"
            }
        }
    }

    func openLogsFolder() {
        try? FileManager.default.createDirectory(at: SessionLog.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(SessionLog.directory)
    }

    /// Apaga todos os logs (a confirmação fica na interface).
    func clearLogs() {
        Task {
            await sessionLog.clearAll()
            logEventCount = 0
            loggedMissingSigns.removeAll()
            record("session.start", [
                "device": selectedDevice?.name ?? "—",
                "channels": settings.channels.map { $0 + 1 },
                "settings": settings.logSummary,
            ])
            refreshLogs()
        }
    }

    // MARK: Preferências

    private func settingsChanged(from old: AppSettings) {
        guard settings != old else { return }
        settings.save()

        if settings.deviceUID != old.deviceUID || settings.channels != old.channels {
            restartCapture()
        }
        if settings.deviceUID != old.deviceUID {
            restartScanner()
        }
        if settings.gainDB != old.gainDB {
            capture?.gain = settings.gainLinear
        }
        if settings.policy != old.policy {
            scheduler.policy = settings.policy
        }
        if settings.glossOptions != old.glossOptions {
            scheduler.glossOptions = settings.glossOptions
        }
        if settings.commitOnComma != old.commitOnComma {
            speech.committer.commaMinWords = settings.commitOnComma ? 6 : 0
        }
        if settings.pauseCommitSeconds != old.pauseCommitSeconds {
            speech.pauseRule.silenceSeconds = settings.pauseCommitSeconds
        }
        if settings.maxWords != old.maxWords {
            segmenter = Segmenter(maxWords: settings.maxWords)
        }
        if settings.logEnabled != old.logEnabled {
            sessionLog.isEnabled = settings.logEnabled
        }
        if settings.appearance != old.appearance {
            scheduleAppearanceUpdate(from: old.appearance)
        }
        if settings.avatar != old.avatar || settings.subtitles != old.subtitles
            || settings.useSignCache != old.useSignCache || settings.policy.baseSpeed != old.policy.baseSpeed {
            appearanceReload = false
            pushOverlayConfig()
        }
        if settings.port != old.port, AppPaths.portOverride == nil {
            restartServer()
        }

        // Sliders mudam várias vezes por segundo: registra no máximo a cada 2 s.
        let now = Date()
        if settings.logSummary != old.logSummary, now.timeIntervalSince(lastSettingsLogged) > 2 {
            lastSettingsLogged = now
            record("settings", ["settings": settings.logSummary])
        }
    }

    private func statusJSON() -> Data {
        struct Status: Encodable {
            let listening: Bool
            let capturing: Bool
            let device: String?
            let channels: [Int]
            let overlays: Int
            let overlaysReady: Int
            let overlaysHidden: Int
            let queued: Int
            let lag: Double
            let speed: Double
            let played: Int
            let dropped: Int
            let playingID: Int?
            let partial: String
            let glossCache: Int
            let signs: SignCache.Stats
            let logFile: String
            let logEvents: Int
        }
        let status = Status(
            listening: isListening,
            capturing: isCapturing,
            device: selectedDevice?.name,
            channels: settings.channels.map { $0 + 1 },
            overlays: overlayClients,
            overlaysReady: overlayReady,
            overlaysHidden: overlayHidden,
            queued: snapshot.queued,
            lag: (snapshot.lag * 10).rounded() / 10,
            speed: snapshot.speed,
            played: snapshot.played,
            dropped: snapshot.dropped,
            playingID: snapshot.playingID,
            partial: partialText,
            glossCache: glossCacheCount,
            signs: signStats,
            logFile: sessionLog.fileURL.path,
            logEvents: logEventCount
        )
        return (try? JSONEncoder().encode(status)) ?? Data("{}".utf8)
    }
}
