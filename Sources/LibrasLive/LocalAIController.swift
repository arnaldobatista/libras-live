import AppKit
import Foundation
import LibrasCore
import LocalAI
import Observation

/// IA local: motor Ollama embutido, modelos instalados, downloads, busca e reescrita de frases.
@MainActor
@Observable
final class LocalAIController {
    enum EngineStatus: Equatable {
        case stopped
        case starting
        case running(version: String, port: Int)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    struct Download: Equatable {
        var completed: Int64 = 0
        var total: Int64 = 0
        var status = "Preparando…"
        var bytesPerSecond: Double = 0

        var fraction: Double? { total > 0 ? min(1, Double(completed) / Double(total)) : nil }
    }

    struct TestRun: Identifiable, Equatable {
        let mode: RewriteMode
        var result: PhraseRewriter.Result?
        var isRunning = true

        var id: RewriteMode { mode }
    }

    // MARK: Estado

    private(set) var engineStatus: EngineStatus = .stopped
    private(set) var installed: [InstalledModel] = []
    private(set) var loaded: [RunningModel] = []
    private(set) var downloads: [String: Download] = [:]
    private(set) var downloadErrors: [String: String] = [:]
    private(set) var lastError: String?
    private(set) var searchResults: [OllamaLibrary.Model] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var tagsByModel: [String: [OllamaLibrary.Tag]] = [:]
    private(set) var loadingTags: Set<String> = []
    private(set) var tests: [TestRun] = []
    private(set) var warmingModel: String?
    private(set) var modelsFolderBytes: Int64 = 0
    let machine = MachineInfo.current()

    /// Um modelo acabou de ser baixado (o app escolhe ele se ainda não houver modelo).
    var onModelInstalled: ((String) -> Void)?
    /// Eventos para o log da sessão.
    var onEvent: ((String, [String: Any]) -> Void)?

    var engineLogURL: URL { engine.configuration.logFile }
    var modelsDirectory: URL { engine.configuration.modelsDirectory }

    // MARK: Componentes

    private let engine: OllamaEngine
    private let rewriter = PhraseRewriter()
    private var client: OllamaClient?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    init() {
        engine = OllamaEngine(configuration: .init(binary: AppPaths.ollamaBinary(), supportDirectory: AppPaths.ollama))
        stateTask = Task { [weak self, engine] in
            for await state in await engine.states() {
                self?.apply(state)
            }
        }
    }

    private func apply(_ state: OllamaEngine.State) {
        switch state {
        case .stopped:
            engineStatus = .stopped
            client = nil
        case .starting:
            engineStatus = .starting
        case let .running(port, version):
            engineStatus = .running(version: version, port: port)
            client = OllamaClient(port: port)
            onEvent?("ai.engine", ["state": "pronto", "version": version, "port": port])
        case let .failed(message):
            engineStatus = .failed(message)
            client = nil
            onEvent?("ai.engine", ["state": "falhou", "message": message])
        }
    }

    // MARK: Motor

    /// Sobe o motor se precisar e devolve o cliente.
    @discardableResult
    func ensureEngine() async -> OllamaClient? {
        if let client, engineStatus.isRunning { return client }
        do {
            let port = try await engine.start()
            lastError = nil
            let client = OllamaClient(port: port)
            self.client = client
            await refresh()
            return client
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func restartEngine() {
        Task {
            await engine.stop()
            await ensureEngine()
        }
    }

    func shutdown() async {
        for task in downloadTasks.values { task.cancel() }
        await engine.stop()
    }

    /// Modelos instalados, carregados e espaço em disco.
    func refresh() async {
        guard let client else { return }
        do {
            installed = try await client.installedModels().sorted { $0.name < $1.name }
            loaded = (try? await client.runningModels()) ?? []
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        let directory = modelsDirectory
        modelsFolderBytes = await Task.detached(priority: .utility) { Self.folderSize(directory) }.value
    }

    func isInstalled(_ name: String) -> Bool {
        installed.contains { ModelCatalog.sameModel($0.name, name) }
    }

    func isLoaded(_ name: String) -> Bool {
        loaded.contains { ModelCatalog.sameModel($0.name, name) }
    }

    // MARK: Downloads

    func download(_ name: String) {
        let model = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, downloadTasks[model] == nil else { return }
        downloads[model] = Download()
        downloadErrors[model] = nil
        onEvent?("ai.pull", ["model": model, "state": "início"])

        downloadTasks[model] = Task { [weak self] in
            guard let self else { return }
            defer {
                downloadTasks[model] = nil
                downloads[model] = nil
            }
            guard let client = await ensureEngine() else {
                downloadErrors[model] = lastError ?? "Motor de IA indisponível."
                return
            }

            var layers: [String: (total: Int64, completed: Int64)] = [:]
            var lastSample = (date: Date(), bytes: Int64(0))
            do {
                for try await event in client.pull(model) {
                    var progress = downloads[model] ?? Download()
                    progress.status = Self.describe(event.status)
                    if let digest = event.digest, let total = event.total {
                        layers[digest] = (total, event.completed ?? layers[digest]?.completed ?? 0)
                        progress.total = layers.values.reduce(0) { $0 + $1.total }
                        progress.completed = layers.values.reduce(0) { $0 + $1.completed }
                        let now = Date()
                        let elapsed = now.timeIntervalSince(lastSample.date)
                        if elapsed >= 1 {
                            let speed = Double(progress.completed - lastSample.bytes) / elapsed
                            progress.bytesPerSecond = progress.bytesPerSecond == 0 ? speed : progress.bytesPerSecond * 0.6 + speed * 0.4
                            lastSample = (now, progress.completed)
                        }
                    }
                    downloads[model] = progress
                }
                onEvent?("ai.pull", ["model": model, "state": "concluído"])
                await rewriter.forgetModels()
                await refresh()
                onModelInstalled?(model)
            } catch is CancellationError {
                onEvent?("ai.pull", ["model": model, "state": "cancelado"])
            } catch {
                if Task.isCancelled {
                    onEvent?("ai.pull", ["model": model, "state": "cancelado"])
                } else {
                    downloadErrors[model] = error.localizedDescription
                    onEvent?("ai.pull", ["model": model, "state": "erro", "message": error.localizedDescription])
                }
            }
        }
    }

    func cancelDownload(_ name: String) {
        downloadTasks[name]?.cancel()
    }

    func dismissDownloadError(_ name: String) {
        downloadErrors[name] = nil
    }

    static func describe(_ status: String?) -> String {
        guard let status else { return "Baixando…" }
        if status.hasPrefix("pulling manifest") { return "Preparando…" }
        if status.hasPrefix("pulling") { return "Baixando…" }
        if status.hasPrefix("verifying") { return "Conferindo…" }
        if status.hasPrefix("writing") || status.hasPrefix("removing") { return "Finalizando…" }
        if status == "success" { return "Pronto" }
        return status
    }

    // MARK: Modelos

    func delete(_ name: String) async {
        guard let client = await ensureEngine() else { return }
        do {
            try await client.delete(name)
            onEvent?("ai.delete", ["model": name])
            await rewriter.forgetModels()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unload(_ name: String) async {
        guard let client = await ensureEngine() else { return }
        try? await client.unload(name)
        await refresh()
    }

    /// Deixa o modelo carregado para a primeira frase não esperar o carregamento (2 a 7 s).
    func warmUp(_ name: String) async {
        guard let client = await ensureEngine(), isInstalled(name) else { return }
        warmingModel = name
        defer { warmingModel = nil }
        do {
            try await client.load(name, keepAlive: "30m")
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Busca

    func search(_ query: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let results = try await OllamaLibrary.search(query)
                guard !Task.isCancelled else { return }
                searchResults = results
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                searchError = "Não foi possível buscar em ollama.com: \(error.localizedDescription)"
            }
        }
    }

    func loadTags(for model: String) {
        guard tagsByModel[model] == nil, !loadingTags.contains(model) else { return }
        loadingTags.insert(model)
        Task { [weak self] in
            defer { self?.loadingTags.remove(model) }
            let tags = (try? await OllamaLibrary.tags(for: model)) ?? []
            self?.tagsByModel[model] = tags
        }
    }

    // MARK: Reescrita

    /// Reescreve um trecho. Sem motor pronto, devolve o original na hora (e liga o motor para as próximas).
    func rewrite(_ text: String, mode: RewriteMode, context: [String], model: String, timeout: TimeInterval) async -> PhraseRewriter.Result {
        guard let client, engineStatus.isRunning else {
            Task { await ensureEngine() }
            return .skipped(text, reason: "motor de IA iniciando", model: model, mode: mode)
        }
        return await rewriter.rewrite(text, mode: mode, context: context, model: model, client: client, timeout: timeout)
    }

    /// Mostra como a frase sai em cada modo (tela IA local).
    func runTests(_ text: String, model: String, timeout: TimeInterval) {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        tests = RewriteMode.allCases.map { TestRun(mode: $0) }
        Task { [weak self] in
            guard let self, let client = await ensureEngine() else { return }
            // Testes não disputam prazo com a transmissão: dão tempo para carregar o modelo.
            for mode in RewriteMode.allCases {
                let result = await rewriter.rewrite(phrase, mode: mode, context: [], model: model, client: client, timeout: max(timeout, 20))
                if let index = tests.firstIndex(where: { $0.mode == mode }) {
                    tests[index].result = result
                    tests[index].isRunning = false
                }
            }
            await refresh()
        }
    }

    // MARK: Pastas

    func revealModelsFolder() {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([modelsDirectory])
    }

    func openEngineLog() {
        guard FileManager.default.fileExists(atPath: engineLogURL.path) else { return }
        NSWorkspace.shared.open(engineLogURL)
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
