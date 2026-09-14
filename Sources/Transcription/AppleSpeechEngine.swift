@preconcurrency import AVFoundation
import Foundation
import os
import Speech

public enum SpeechEngineError: Error, LocalizedError {
    case unsupportedLocale(String)
    case noAudioFormat
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLocale(id): "O reconhecimento de fala da Apple não suporta \(id) neste Mac."
        case .noAudioFormat: "Não foi possível obter o formato de áudio do reconhecedor."
        case .alreadyRunning: "O reconhecimento já está rodando."
        }
    }
}

/// Reconhecimento no próprio Mac com `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26).
public final class AppleSpeechEngine: SpeechEngine, @unchecked Sendable {
    public let locale: Locale
    public let events: AsyncStream<TranscriptEvent>

    private let eventContinuation: AsyncStream<TranscriptEvent>.Continuation
    private let log = Logger(subsystem: "LibrasLive", category: "speech")
    private let state = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(initialState: nil)

    private var analyzer: SpeechAnalyzer?
    private var audioTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    public init(locale: Locale = Locale(identifier: "pt-BR")) {
        self.locale = locale
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    deinit {
        eventContinuation.finish()
    }

    public static func isSupported(locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == wanted }
    }

    public func start() async throws {
        guard analyzer == nil else { throw SpeechEngineError.alreadyRunning }
        guard await Self.isSupported(locale: locale) else {
            throw SpeechEngineError.unsupportedLocale(locale.identifier(.bcp47))
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log.info("Baixando modelo de fala para \(self.locale.identifier(.bcp47), privacy: .public)")
            try await request.downloadAndInstall()
        }

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: targetFormat)

        let (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let (audioStream, audioContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(400))

        try await analyzer.start(inputSequence: inputStream)
        self.analyzer = analyzer
        state.withLock { $0 = audioContinuation }

        let events = eventContinuation
        let log = self.log
        resultsTask = Task.detached(priority: .userInitiated) {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    events.yield(result.isFinal ? .final(text) : .partial(text))
                }
            } catch {
                log.error("Resultados interrompidos: \(error.localizedDescription, privacy: .public)")
                if !Task.isCancelled { events.yield(.failure(error.localizedDescription)) }
            }
        }

        audioTask = Task.detached(priority: .userInitiated) {
            let converter = BufferConverter(target: targetFormat)
            for await buffer in audioStream {
                if let converted = converter.convert(buffer) {
                    inputBuilder.yield(AnalyzerInput(buffer: converted))
                }
            }
            inputBuilder.finish()
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        state.withLock { $0 }?.yield(buffer)
    }

    public func stop() async {
        let continuation = state.withLock { current -> AsyncStream<AVAudioPCMBuffer>.Continuation? in
            defer { current = nil }
            return current
        }
        continuation?.finish()
        await audioTask?.value

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }
        await resultsTask?.value

        analyzer = nil
        audioTask = nil
        resultsTask = nil
    }
}

/// Converte o áudio capturado para o formato pedido pelo reconhecedor.
final class BufferConverter {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if buffer.format == target { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
