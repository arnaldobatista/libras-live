import Foundation

/// Configuração enviada ao overlay. Campos nulos não alteram o estado atual.
public struct OverlayConfig: Codable, Sendable, Equatable {
    public var avatar: String?
    public var subtitles: Bool?
    public var speed: Double?
    public var signsBaseUrl: String?
    /// JSON de personalização para o `CustomizationBridge.ApplyJSON` ("" = aparência original).
    public var appearance: String?
    /// Muda a cada alteração de aparência; o overlay só aplica/recarrega quando muda.
    public var appearanceRevision: Int?
    /// A mudança não pode ser aplicada por JSON (voltar ao original): recarregar o player.
    public var appearanceReload: Bool?

    public init(
        avatar: String? = nil,
        subtitles: Bool? = nil,
        speed: Double? = nil,
        signsBaseUrl: String? = nil,
        appearance: String? = nil,
        appearanceRevision: Int? = nil,
        appearanceReload: Bool? = nil
    ) {
        self.avatar = avatar
        self.subtitles = subtitles
        self.speed = speed
        self.signsBaseUrl = signsBaseUrl
        self.appearance = appearance
        self.appearanceRevision = appearanceRevision
        self.appearanceReload = appearanceReload
    }
}

/// Mensagens do app para o overlay.
public enum OverlayOutbound: Sendable, Equatable {
    case gloss(id: Int, gloss: String, text: String, speed: Double)
    case config(OverlayConfig)
    case stop
    case caption(text: String, final: Bool)

    private struct Envelope: Encodable {
        var type: String
        var id: Int?
        var gloss: String?
        var text: String?
        var speed: Double?
        var final: Bool?
        var avatar: String?
        var subtitles: Bool?
        var signsBaseUrl: String?
        var appearance: String?
        var appearanceRevision: Int?
        var appearanceReload: Bool?
    }

    public func json() -> String {
        let envelope: Envelope
        switch self {
        case let .gloss(id, gloss, text, speed):
            envelope = Envelope(type: "gloss", id: id, gloss: gloss, text: text, speed: speed)
        case let .config(config):
            envelope = Envelope(
                type: "config",
                speed: config.speed,
                avatar: config.avatar,
                subtitles: config.subtitles,
                signsBaseUrl: config.signsBaseUrl,
                appearance: config.appearance,
                appearanceRevision: config.appearanceRevision,
                appearanceReload: config.appearanceReload
            )
        case .stop:
            envelope = Envelope(type: "stop")
        case let .caption(text, final):
            envelope = Envelope(type: "caption", text: text, final: final)
        }
        let data = (try? JSONEncoder().encode(envelope)) ?? Data("{\"type\":\"noop\"}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Mensagens do overlay para o app.
public struct OverlayInbound: Decodable, Sendable, Equatable {
    public enum Kind: String, Decodable, Sendable {
        case hello, ready, visibility, playing, ended, progress, avatar, error
    }

    public var type: Kind
    public var id: Int?
    public var reason: String?
    public var message: String?
    public var counter: Int?
    public var total: Int?
    public var loaded: Bool?
    public var visible: Bool?

    public init(type: Kind, id: Int? = nil, reason: String? = nil, loaded: Bool? = nil, visible: Bool? = nil) {
        self.type = type
        self.id = id
        self.reason = reason
        self.loaded = loaded
        self.visible = visible
    }

    public static func decode(_ text: String) -> OverlayInbound? {
        try? JSONDecoder().decode(OverlayInbound.self, from: Data(text.utf8))
    }
}
