import Foundation

/// Detecta pausas na fala pelo nível do áudio, com piso de ruído adaptativo.
///
/// O reconhecedor manda hipóteses em rajadas de ~1 s; "sem atualização por 0,8 s" não é
/// pausa (em live real isso cortou palavras ao meio: `multipl`, `jogu`). Aqui a pausa vem
/// do próprio áudio: nível abaixo do piso de ruído + margem.
public struct VoiceActivityDetector: Sendable, Equatable {
    /// Quanto acima do piso de ruído o nível precisa estar para contar como fala.
    public var marginDB: Float
    /// Nível mínimo (dBFS) para considerar fala, mesmo com piso muito baixo.
    public var minimumSpeechDB: Float

    /// Piso de ruído estimado (dBFS).
    public private(set) var noiseFloorDB: Float = -60
    public private(set) var silenceStartedAt: Date?
    public private(set) var lastSpeechAt: Date?
    private var lastObservation: Date?

    public init(marginDB: Float = 10, minimumSpeechDB: Float = -50) {
        self.marginDB = marginDB
        self.minimumSpeechDB = minimumSpeechDB
    }

    public var thresholdDB: Float { max(noiseFloorDB + marginDB, minimumSpeechDB) }

    /// Registra um nível (RMS em dBFS). Chamar ~20 vezes por segundo.
    public mutating func observe(levelDB: Float, at now: Date) {
        guard let previous = lastObservation else {
            // Primeira medida: parte do nível atual em vez de um piso arbitrário.
            noiseFloorDB = levelDB
            lastObservation = now
            silenceStartedAt = now
            return
        }
        let elapsed = Float(now.timeIntervalSince(previous))
        lastObservation = now

        // Piso: desce rápido até sons mais baixos e sobe devagar (~3 dB/s) para seguir ruído crescente.
        if levelDB < noiseFloorDB {
            noiseFloorDB += (levelDB - noiseFloorDB) * min(1, elapsed * 8)
        } else {
            noiseFloorDB += min(levelDB - noiseFloorDB, 3 * elapsed)
        }

        if levelDB >= thresholdDB {
            lastSpeechAt = now
            silenceStartedAt = nil
        } else if silenceStartedAt == nil {
            silenceStartedAt = now
        }
    }

    /// Há quanto tempo o áudio está em silêncio (0 se há fala).
    public func silenceDuration(at now: Date) -> TimeInterval {
        silenceStartedAt.map { now.timeIntervalSince($0) } ?? 0
    }

    public mutating func reset() {
        silenceStartedAt = nil
        lastSpeechAt = nil
        lastObservation = nil
    }
}

/// Decide quando confirmar o trecho pendente por pausa.
public struct PauseCommitRule: Sendable, Equatable {
    /// Silêncio mínimo no áudio.
    public var silenceSeconds: TimeInterval
    /// A hipótese precisa estar parada por mais que o ritmo do reconhecedor (~1 s),
    /// para a última palavra estar completa.
    public var stableSeconds: TimeInterval
    /// Sem mudança por esse tempo confirma mesmo sem silêncio detectável (ruído, música de fundo).
    public var stalledSeconds: TimeInterval

    public init(silenceSeconds: TimeInterval = 0.6, stableSeconds: TimeInterval = 1.2, stalledSeconds: TimeInterval = 2.5) {
        self.silenceSeconds = silenceSeconds
        self.stableSeconds = stableSeconds
        self.stalledSeconds = stalledSeconds
    }

    public enum Decision: Equatable, Sendable {
        case wait
        case silence
        case stalled
    }

    public func decide(silence: TimeInterval, unchangedFor unchanged: TimeInterval) -> Decision {
        if silenceSeconds > 0, silence >= silenceSeconds, unchanged >= stableSeconds { return .silence }
        if unchanged >= stalledSeconds { return .stalled }
        return .wait
    }
}
