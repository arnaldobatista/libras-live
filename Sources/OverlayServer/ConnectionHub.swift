import Foundation

/// Conexões WebSocket abertas pelos overlays.
actor ConnectionHub {
    private var clients: [UUID: AsyncStream<String>.Continuation] = [:]
    private var lastConfig: String?

    func add() -> (UUID, AsyncStream<String>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(64))
        clients[id] = continuation
        if let lastConfig { continuation.yield(lastConfig) }
        return (id, stream)
    }

    func remove(_ id: UUID) {
        clients.removeValue(forKey: id)?.finish()
    }

    func broadcast(_ text: String) {
        for client in clients.values { client.yield(text) }
    }

    /// Guarda a configuração para reenviar a quem conectar depois.
    func broadcastConfig(_ text: String) {
        lastConfig = text
        broadcast(text)
    }

    func closeAll() {
        for client in clients.values { client.finish() }
        clients.removeAll()
    }
}
