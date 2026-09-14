// libras-probe: diagnóstico sem interface.
//
//   swift run libras-probe devices
//   swift run libras-probe level <uid|nome> <canais ex: 1,2> [segundos]
//   swift run libras-probe scan <uid|nome> [segundos]      (pico de cada canal)
//   swift run libras-probe transcribe <arquivo de áudio>
//   swift run libras-probe listen <uid|nome> <canais> [segundos]
//   swift run libras-probe gloss "texto em português"
//   swift run libras-probe simulate <sessao.tsv> [--timeline] [--grid]   (compara configurações com uma live real)
//   swift run libras-probe log <sessao.jsonl>                   (log de sessão em texto legível)

@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import LibrasCore
import os
import OverlayServer
import Transcription

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func findDevice(_ query: String) -> AudioDevice {
    let devices = AudioDevices.inputDevices()
    if let device = devices.first(where: { $0.uid == query })
        ?? devices.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) {
        return device
    }
    fail("Dispositivo não encontrado: \(query). Use `libras-probe devices`.")
}

func parseChannels(_ text: String) -> [Int] {
    let channels = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { $0 - 1 }
    guard !channels.isEmpty else { fail("Canais inválidos: \(text) (use 1-based, ex: 1,2)") }
    return channels
}

func meter(_ level: AudioLevel) -> String {
    let db = AudioLevel.decibels(level.peak)
    let filled = Int((db + 60) / 60 * 30)
    return String(repeating: "█", count: max(0, filled)) + String(repeating: "·", count: max(0, 30 - filled)) + String(format: " %6.1f dB", db)
}

func printEvents(of engine: AppleSpeechEngine, started: Date) -> Task<Void, Never> {
    Task {
        var committer = TranscriptCommitter()
        var lastPartial = ""
        for await event in engine.events {
            let t = String(format: "%6.2fs", Date().timeIntervalSince(started))
            switch event {
            case let .partial(text):
                for segment in committer.partial(text) { print("\(t)  ✔ confirmado (provisório estável): \(segment)") }
                let pending = committer.pending(in: text)
                if pending != lastPartial, !pending.isEmpty {
                    lastPartial = pending
                    print("\(t)  … \(pending)")
                }
            case let .final(text):
                lastPartial = ""
                for segment in committer.final(text) { print("\(t)  ✔ confirmado (final): \(segment)") }
            case let .failure(message):
                print("\(t)  ✘ \(message)")
            }
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("Uso: libras-probe devices | level <disp> <canais> [s] | transcribe <arquivo> | listen <disp> <canais> [s] | gloss <texto>")
}

switch command {
case "devices":
    for device in AudioDevices.inputDevices() {
        print("\(device.name) — \(device.inputChannels) canais @ \(Int(device.sampleRate)) Hz")
        print("  uid: \(device.uid)")
        let named = device.channelNames.enumerated().compactMap { index, name in name.map { "\(index + 1)=\($0)" } }
        if !named.isEmpty { print("  canais: \(named.joined(separator: ", "))") }
    }

case "level":
    guard arguments.count >= 3 else { fail("Uso: libras-probe level <disp> <canais> [segundos]") }
    let device = findDevice(arguments[1])
    let channels = parseChannels(arguments[2])
    let seconds = Double(arguments.count > 3 ? arguments[3] : "5") ?? 5
    let capture = ChannelCapture(device: device, channels: channels)
    print("Capturando \(device.name) canais \(channels.map { $0 + 1 }) por \(Int(seconds)) s")
    do {
        try capture.start(onBuffer: { _ in }, onLevel: { level in
            print("\r\(meter(level))", terminator: "")
            fflush(stdout)
        })
    } catch {
        fail(error.localizedDescription)
    }
    try await Task.sleep(for: .seconds(seconds))
    capture.stop()
    print()

case "scan":
    guard arguments.count >= 2 else { fail("Uso: libras-probe scan <disp> [segundos]") }
    let device = findDevice(arguments[1])
    let seconds = Double(arguments.count > 2 ? arguments[2] : "5") ?? 5
    let scanner = ChannelScanner(device: device)
    let maxima = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: device.inputChannels))
    try scanner.start { levels in
        maxima.withLock { current in
            for index in levels.indices { current[index] = max(current[index], levels[index]) }
        }
    }
    print("Varrendo \(device.name) (\(device.inputChannels) canais) por \(Int(seconds)) s...")
    try await Task.sleep(for: .seconds(seconds))
    scanner.stop()
    for (index, peak) in maxima.withLock({ $0 }).enumerated() {
        let db = AudioLevel.decibels(peak)
        print(String(format: "  canal %2d  %@", index + 1, meter(AudioLevel(rms: peak, peak: peak))), db > -59 ? "◀" : "")
    }

case "transcribe":
    guard arguments.count >= 2 else { fail("Uso: libras-probe transcribe <arquivo>") }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[1]))
    let format = file.processingFormat
    print("Arquivo: \(format.sampleRate) Hz, \(format.channelCount) canal(is), \(String(format: "%.1f", Double(file.length) / format.sampleRate)) s")

    let engine = AppleSpeechEngine()
    let started = Date()
    try await engine.start()
    print(String(format: "Reconhecedor pronto em %.2f s\n", Date().timeIntervalSince(started)))

    // Mesmo fluxo de eventos para a regra nova (SpeechCommitController) e a antiga (0,8 s sem atualização).
    final class Comparison: @unchecked Sendable {
        let lock = NSLock()
        var current = SpeechCommitController()
        var legacy = TranscriptCommitter(streamChunkWords: 0)
        var legacyHypothesis = ""
        var legacyPartialAt: Date?
        let start = Date()

        func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(start)) }
        func show(_ label: String, _ texts: [String]) {
            for text in texts { print("\(stamp())  \(label)  \(text)") }
        }
        func partial(_ text: String) {
            lock.withLock {
                let now = Date()
                show("[nova]  ", current.partial(text, at: now).map { "\($0.text)  (\($0.source.rawValue))" })
                legacyHypothesis = text
                legacyPartialAt = now
                show("[antiga]", legacy.partial(text))
            }
        }
        func final(_ text: String) {
            lock.withLock {
                show("[nova]  ", current.final(text).map { "\($0.text)  (final)" })
                legacyHypothesis = ""
                legacyPartialAt = nil
                show("[antiga]", legacy.final(text).map { "\($0)  (final)" })
            }
        }
        func tick(level: Float) {
            lock.withLock {
                let now = Date()
                current.level(level, at: now)
                show("[nova]  ", current.tick(at: now).map { String(format: "%@  (%@, silêncio %.1fs, parado %.1fs)", $0.text, $0.source.rawValue, $0.silence, $0.unchanged) })
                if let at = legacyPartialAt, now.timeIntervalSince(at) >= 0.8 {
                    show("[antiga]", legacy.flush(legacyHypothesis).map { "\($0)  (pausa 0,8 s)" })
                }
            }
        }
    }

    let comparison = Comparison()
    let printer = Task {
        for await event in engine.events {
            switch event {
            case let .partial(text): comparison.partial(text)
            case let .final(text): comparison.final(text)
            case let .failure(message): print("✘ \(message)")
            }
        }
    }

    // Alimenta em tempo real (blocos de 50 ms), como a captura ao vivo, medindo o nível de cada bloco.
    let chunk = AVAudioFrameCount(format.sampleRate / 20)
    let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
        try file.read(into: buffer, frameCount: chunk)
        guard let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let destination = output.floatChannelData else { break }
        output.frameLength = buffer.frameLength
        var sumSquares: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<Int(format.channelCount) { sum += source[channel][frame] }
            let sample = sum / Float(format.channelCount)
            destination[0][frame] = sample
            sumSquares += sample * sample
        }
        engine.append(output)
        let rms = sqrt(sumSquares / Float(max(buffer.frameLength, 1)))
        comparison.tick(level: AudioLevel.decibels(rms))
        try await Task.sleep(for: .milliseconds(50))
    }
    for _ in 0..<40 {
        comparison.tick(level: -60)
        try await Task.sleep(for: .milliseconds(50))
    }
    await engine.stop()
    try await Task.sleep(for: .milliseconds(300))
    printer.cancel()

case "listen":
    guard arguments.count >= 3 else { fail("Uso: libras-probe listen <disp> <canais> [segundos]") }
    let device = findDevice(arguments[1])
    let channels = parseChannels(arguments[2])
    let seconds = Double(arguments.count > 3 ? arguments[3] : "20") ?? 20

    let engine = AppleSpeechEngine()
    try await engine.start()
    let printer = printEvents(of: engine, started: Date())
    let capture = ChannelCapture(device: device, channels: channels)
    try capture.start(onBuffer: { engine.append($0) })
    print("Ouvindo \(device.name) canais \(channels.map { $0 + 1 }) por \(Int(seconds)) s — fale algo.")
    try await Task.sleep(for: .seconds(seconds))
    capture.stop()
    await engine.stop()
    printer.cancel()

case "gloss":
    guard arguments.count >= 2 else { fail("Uso: libras-probe gloss <texto>") }
    let service = GlossService()
    let text = arguments.dropFirst().joined(separator: " ")
    for segment in Segmenter().split(text) {
        let result = await service.translate(segment)
        print(String(format: "%@ → %@ (%@, %.0f ms)", segment, result.gloss, result.source.rawValue, result.duration * 1000))
    }

case "log":
    guard arguments.count >= 2 else { fail("Uso: libras-probe log <sessao.jsonl>") }
    print(SessionLogFormatter.format(try String(contentsOfFile: arguments[1], encoding: .utf8)), terminator: "")

case "simulate":
    guard arguments.count >= 2 else { fail("Uso: libras-probe simulate <sessao.tsv> [--timeline]") }
    let phrases = PlaybackSimulator.parseTSV(try String(contentsOfFile: arguments[1], encoding: .utf8))
    guard !phrases.isEmpty else { fail("Nenhuma frase no arquivo (formato: HH:MM:SS<TAB>texto<TAB>glosa).") }

    // Consulta o dicionário real para cada sinal e alternativa.
    let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LibrasLive/signs", isDirectory: true)
    let cache = SignCache(directory: cacheDirectory)
    let allTokens = Array(Set(phrases.flatMap(\.tokens)))
    var availability = await cache.availability(for: allTokens)
    availability.merge(await cache.availability(for: GlossOptimizer.lookupNames(for: allTokens, availability: availability))) { a, _ in a }
    let missing = allTokens.filter { availability[$0] == false }.sorted()
    print("\(phrases.count) frases · \(allTokens.count) sinais distintos · sem sinal no dicionário: \(missing.joined(separator: ", "))\n")

    let speeds = (base: 2.0, max: 3.0)
    let configurations: [(String, PlaybackSimulator)] = [
        ("antes (v0.1)", PlaybackSimulator(
            policy: BacklogPolicy(baseSpeed: speeds.base, maxSpeed: speeds.max, speedUpAfter: 5, dropAfter: 15,
                                  mergePhrases: false, compactWhenBehind: false, dropRepeats: false),
            glossOptions: .init(removePunctuationPauses: false, unknownWords: .spell))),
        ("+ juntar frases", PlaybackSimulator(
            policy: BacklogPolicy(baseSpeed: speeds.base, maxSpeed: speeds.max, speedUpAfter: 5, dropAfter: 15,
                                  mergePhrases: true, compactWhenBehind: false, dropRepeats: false),
            glossOptions: .init(removePunctuationPauses: false, unknownWords: .spell))),
        ("+ otimizar glosa", PlaybackSimulator(
            policy: BacklogPolicy(baseSpeed: speeds.base, maxSpeed: speeds.max, speedUpAfter: 5, dropAfter: 15,
                                  mergePhrases: true, compactWhenBehind: true, dropRepeats: false),
            glossOptions: .init(removePunctuationPauses: true, unknownWords: .spellShort))),
        ("agora (tudo)", PlaybackSimulator(
            policy: BacklogPolicy(baseSpeed: speeds.base, maxSpeed: speeds.max, speedUpAfter: 5, dropAfter: 15),
            glossOptions: .init())),
    ]

    print("configuração         envios  tocadas  descartadas  parado  vel.média  atraso médio")
    var reports: [(String, PlaybackSimulator.Report)] = []
    for (name, simulator) in configurations {
        let report = simulator.run(phrases, availability: availability)
        reports.append((name, report))
        let dropped = report.droppedTotal
        let reasons = report.dropped.filter { $0.key != .empty }.map { "\($0.value) \($0.key.rawValue)" }.joined(separator: ", ")
        print(String(format: "%-20@  %6d  %7d  %4d (%3.0f%%)  %5.0fs  %8.2f×  %9.1fs   %@",
                     name as NSString, report.dispatches, report.played, dropped,
                     100 * Double(dropped) / Double(max(report.phrases, 1)),
                     report.idleSeconds, report.averageSpeed, report.averageLag, reasons))
    }

    if arguments.contains("--grid") {
        print("\nVariações (tudo ligado, velocidade 2–3×):")
        print("descartar após  máx/envio  vel.máx  descartadas  atraso médio  atraso máx")
        for dropAfter in [15.0, 20.0, 25.0, 30.0] {
            for maxBatch in [12.0, 20.0] {
                for maxSpeed in [3.0, 3.5] {
                    let simulator = PlaybackSimulator(
                        policy: BacklogPolicy(baseSpeed: speeds.base, maxSpeed: maxSpeed, speedUpAfter: 5, dropAfter: dropAfter, maxBatchSeconds: maxBatch),
                        glossOptions: .init())
                    let report = simulator.run(phrases, availability: availability)
                    print(String(format: "%11.0fs  %8.0fs  %6.1f×  %4d (%3.0f%%)  %11.1fs  %9.1fs",
                                 dropAfter, maxBatch, maxSpeed, report.droppedTotal,
                                 100 * Double(report.droppedTotal) / Double(max(report.phrases, 1)),
                                 report.averageLag, report.lags.max() ?? 0))
                }
            }
        }
    }

    if arguments.contains("--timeline") {
        for (name, report) in reports {
            print("\n== \(name) ==")
            report.timeline.forEach { print($0) }
        }
    }

default:
    fail("Comando desconhecido: \(command)")
}
