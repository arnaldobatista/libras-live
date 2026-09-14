import Foundation

/// Decide quando um trecho da fala está pronto para tradução.
///
/// Junta as regras que antes ficavam espalhadas no app:
/// - frase estável na hipótese provisória (`TranscriptCommitter.partial`);
/// - resultado final do reconhecedor;
/// - pausa real: silêncio no áudio + hipótese parada (`PauseCommitRule`);
/// - parada da escuta.
public struct SpeechCommitController: Sendable {
    public struct Commit: Sendable, Equatable {
        public enum Source: String, Sendable {
            case stable = "estável"
            case final = "final"
            case silence = "pausa"
            case stalled = "parado"
            case stop = "parada"
        }

        public let text: String
        public let source: Source
        /// Silêncio medido e tempo sem mudança na hipótese no momento da decisão (só pausas).
        public let silence: TimeInterval
        public let unchanged: TimeInterval
    }

    public var committer: TranscriptCommitter
    public var vad: VoiceActivityDetector
    public var pauseRule: PauseCommitRule

    public private(set) var hypothesis = ""
    public private(set) var hypothesisChangedAt: Date?

    public init(
        committer: TranscriptCommitter = TranscriptCommitter(),
        vad: VoiceActivityDetector = VoiceActivityDetector(),
        pauseRule: PauseCommitRule = PauseCommitRule()
    ) {
        self.committer = committer
        self.vad = vad
        self.pauseRule = pauseRule
    }

    /// Parte da hipótese ainda não confirmada.
    public var pendingText: String { committer.pending(in: hypothesis) }

    public mutating func level(_ db: Float, at now: Date) {
        vad.observe(levelDB: db, at: now)
    }

    public mutating func partial(_ text: String, at now: Date) -> [Commit] {
        if text != hypothesis {
            hypothesis = text
            hypothesisChangedAt = now
        }
        return committer.partial(text, at: now).map { Commit(text: $0, source: .stable, silence: 0, unchanged: 0) }
    }

    public mutating func final(_ text: String) -> [Commit] {
        hypothesis = ""
        hypothesisChangedAt = nil
        return committer.final(text).map { Commit(text: $0, source: .final, silence: 0, unchanged: 0) }
    }

    /// Chamar periodicamente (~5 vezes por segundo).
    public mutating func tick(at now: Date) -> [Commit] {
        guard let changedAt = hypothesisChangedAt, !pendingText.isEmpty else { return [] }
        let silence = vad.silenceDuration(at: now)
        let unchanged = now.timeIntervalSince(changedAt)

        let source: Commit.Source
        switch pauseRule.decide(silence: silence, unchangedFor: unchanged) {
        case .wait: return []
        case .silence: source = .silence
        case .stalled: source = .stalled
        }
        return committer.flush(hypothesis).map { Commit(text: $0, source: source, silence: silence, unchanged: unchanged) }
    }

    public mutating func stop() -> [Commit] {
        defer {
            hypothesis = ""
            hypothesisChangedAt = nil
            vad.reset()
        }
        return committer.final(hypothesis).map { Commit(text: $0, source: .stop, silence: 0, unchanged: 0) }
    }
}
