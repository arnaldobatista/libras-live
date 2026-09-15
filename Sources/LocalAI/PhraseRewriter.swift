import Foundation
import LibrasCore

/// Reescreve um trecho com o modelo local, dentro de um prazo. Qualquer problema (prazo, erro,
/// resposta estranha) devolve o texto original: a tradução nunca fica esperando a IA.
public actor PhraseRewriter {
    public struct Result: Sendable, Equatable {
        public enum Status: String, Sendable {
            /// A IA mudou o texto.
            case rewritten
            /// A IA devolveu o mesmo texto.
            case unchanged
            /// Ficou o original (prazo, erro ou resposta recusada).
            case fallback
        }

        public let text: String
        public let original: String
        public let status: Status
        public let reason: String?
        public let seconds: TimeInterval
        public let model: String
        public let mode: RewriteMode
        /// Resposta recusada pela validação (para entender o motivo no log).
        public var rejectedOutput: String?

        public init(text: String, original: String, status: Status, reason: String?, seconds: TimeInterval, model: String, mode: RewriteMode, rejectedOutput: String? = nil) {
            self.text = text
            self.original = original
            self.status = status
            self.reason = reason
            self.seconds = seconds
            self.model = model
            self.mode = mode
            self.rejectedOutput = rejectedOutput
        }

        /// O original segue sem passar pela IA.
        public static func skipped(_ text: String, reason: String, model: String, mode: RewriteMode) -> Result {
            Result(text: text, original: text, status: .fallback, reason: reason, seconds: 0, model: model, mode: mode)
        }
    }

    private var thinkingModels: [String: Bool] = [:]

    public init() {}

    public func rewrite(
        _ text: String,
        mode: RewriteMode,
        context: [String],
        model: String,
        client: OllamaClient,
        timeout: TimeInterval,
        keepAlive: String = "30m"
    ) async -> Result {
        let started = Date()
        func finish(_ status: Result.Status, _ output: String, reason: String? = nil, rejected: String? = nil) -> Result {
            Result(text: output, original: text, status: status, reason: reason, seconds: Date().timeIntervalSince(started), model: model, mode: mode, rejectedOutput: rejected)
        }

        let prompt = RewritePrompt.make(text: text, mode: mode, context: context)
        let thinks = await thinks(model, client: client)

        do {
            let reply = try await withDeadline(timeout) {
                try await client.chat(
                    model: model,
                    messages: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)],
                    options: .init(temperature: prompt.temperature, numPredict: prompt.maxTokens),
                    think: thinks ? false : nil,
                    keepAlive: keepAlive,
                    timeout: timeout + 1
                )
            }
            switch RewriteValidator.validate(original: text, output: reply.content, mode: mode) {
            case let .accepted(output, changed):
                return finish(changed ? .rewritten : .unchanged, output)
            case let .rejected(reason):
                return finish(.fallback, text, reason: reason, rejected: RewriteValidator.clean(reply.content))
            }
        } catch is DeadlineExceeded {
            return finish(.fallback, text, reason: "passou do tempo máximo")
        } catch is CancellationError {
            return finish(.fallback, text, reason: "cancelado")
        } catch {
            return finish(.fallback, text, reason: error.localizedDescription)
        }
    }

    /// Esquece o que sabe dos modelos (ex.: depois de baixar ou excluir).
    public func forgetModels() {
        thinkingModels = [:]
    }

    private func thinks(_ model: String, client: OllamaClient) async -> Bool {
        if let known = thinkingModels[model] { return known }
        guard let info = try? await client.show(model) else { return false }
        thinkingModels[model] = info.thinks
        return info.thinks
    }
}

struct DeadlineExceeded: Error {}

/// Roda `operation` e desiste depois de `seconds` (a operação é cancelada).
func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        return first
    }
}
