@preconcurrency import AVFoundation
import Foundation

public enum TranscriptEvent: Sendable, Equatable {
    /// Hipótese provisória (muda enquanto a pessoa fala). Só para prévia.
    case partial(String)
    /// Trecho finalizado pelo reconhecedor. Vai para tradução.
    case final(String)
    /// O reconhecedor parou por erro e precisa ser reiniciado.
    case failure(String)
}

/// Motor de reconhecimento de fala plugável.
public protocol SpeechEngine: AnyObject, Sendable {
    var events: AsyncStream<TranscriptEvent> { get }
    func start() async throws
    /// Chamado na thread de áudio: precisa ser barato.
    func append(_ buffer: AVAudioPCMBuffer)
    func stop() async
}
