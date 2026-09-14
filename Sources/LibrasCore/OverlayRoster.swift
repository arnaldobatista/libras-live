import Foundation

/// Overlays conectados e quem ainda precisa terminar a glosa atual.
///
/// Com vários overlays (duas cenas no OBS, um monitor no navegador), a fila só avança
/// quando todos os overlays prontos e **visíveis** terminam. Overlays ocultos rodam o
/// Unity a ~0 fps e não podem segurar nem apressar a fila.
public struct OverlayRoster: Sendable, Equatable {
    public struct Client: Sendable, Equatable {
        public var ready = false
        public var visible = true
    }

    public private(set) var clients: [UUID: Client] = [:]
    public private(set) var playingItem: Int?
    private var awaiting: Set<UUID> = []

    public init() {}

    public var total: Int { clients.count }
    public var readyCount: Int { clients.values.filter(\.ready).count }
    public var hiddenCount: Int { clients.values.filter { $0.ready && !$0.visible }.count }
    public var canPlay: Bool { readyCount > 0 }

    public mutating func connect(_ id: UUID) {
        clients[id] = Client()
    }

    /// - Returns: `true` se a glosa atual acabou de ser concluída por essa desconexão.
    public mutating func disconnect(_ id: UUID) -> Bool {
        clients.removeValue(forKey: id)
        return release(id)
    }

    /// Atualiza estado a partir de `hello`, `ready` e `visibility`.
    /// - Returns: `true` se a glosa atual foi concluída (ex.: único overlay aguardado ficou oculto).
    public mutating func apply(_ message: OverlayInbound, from id: UUID) -> Bool {
        guard clients[id] != nil else { return false }
        if let visible = message.visible { clients[id]?.visible = visible }

        switch message.type {
        case .hello:
            clients[id]?.ready = message.loaded ?? false
        case .ready:
            clients[id]?.ready = true
        default:
            break
        }

        if clients[id]?.visible == false || clients[id]?.ready == false {
            return release(id)
        }
        return false
    }

    /// Registra quem precisa terminar o item que acabou de ser enviado.
    public mutating func beginPlayback(itemID: Int) {
        let ready = clients.filter { $0.value.ready }
        let visible = ready.filter { $0.value.visible }
        awaiting = Set((visible.isEmpty ? ready : visible).keys)
        playingItem = itemID
    }

    /// - Returns: `true` quando todos os overlays aguardados terminaram o item.
    public mutating func ended(itemID: Int, from id: UUID) -> Bool {
        guard playingItem == itemID else { return false }
        return release(id)
    }

    public mutating func cancelPlayback() {
        awaiting.removeAll()
        playingItem = nil
    }

    private mutating func release(_ id: UUID) -> Bool {
        guard playingItem != nil, awaiting.remove(id) != nil, awaiting.isEmpty else { return false }
        playingItem = nil
        return true
    }
}
