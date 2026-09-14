import CoreGraphics
import Foundation

/// Aparência personalizada do avatar do VLibras: cores e logo na camisa.
///
/// O player aceita um JSON com estas chaves no `CustomizationBridge.ApplyJSON`
/// (formato lido dos metadados do próprio build do avatar):
/// `cabelo`, `calca`, `camisa`, `corpo`, `iris`, `olhos`, `sombrancelhas` (cores `#RRGGBB`),
/// `logo` (URL de PNG 500 × 500 transparente) e `pos` (`chest`, `center` ou `centerAndChest`).
public struct AvatarAppearance: Codable, Sendable, Equatable {
    public enum LogoMode: String, Codable, CaseIterable, Sendable {
        /// Mantém a logo original do VLibras.
        case vlibras
        /// Logo enviada pelo usuário.
        case custom
        /// Camisa lisa.
        case none
    }

    public enum LogoPosition: String, Codable, CaseIterable, Sendable {
        case chest
        case center
        case centerAndChest
    }

    public var enabled = false
    public var hair = "#1E0F1A"
    public var eyebrows = "#1E0F1A"
    public var skin = "#FFDBCB"
    public var iris = "#9A8C86"
    public var eyes = "#FFFFFF"
    public var shirt = "#1B35FF"
    public var pants = "#0D0D0F"

    public var logoMode: LogoMode = .vlibras
    public var logoPosition: LogoPosition = .chest
    /// Tamanho da logo dentro da área segura (0,3 a 1).
    public var logoScale = 1.0
    /// Deslocamento dentro da área segura (-1 a 1).
    public var logoOffsetX = 0.0
    public var logoOffsetY = 0.0
    /// Arquivo original da logo enviada (dentro da pasta de aparência).
    public var logoSourceFile: String?

    public init() {}

    /// Cores originais do Ícaro (JSON de exemplo embutido no player).
    public static let vlibrasColors = AvatarAppearance()

    /// JSON para `ApplyJSON`. `logoURL` vazio mantém a logo atual do avatar.
    public func personalizationJSON(logoURL: String) -> String {
        let object: [String: String] = [
            "cabelo": Self.normalizedHex(hair) ?? Self.vlibrasColors.hair,
            "calca": Self.normalizedHex(pants) ?? Self.vlibrasColors.pants,
            "camisa": Self.normalizedHex(shirt) ?? Self.vlibrasColors.shirt,
            "corpo": Self.normalizedHex(skin) ?? Self.vlibrasColors.skin,
            "iris": Self.normalizedHex(iris) ?? Self.vlibrasColors.iris,
            "olhos": Self.normalizedHex(eyes) ?? Self.vlibrasColors.eyes,
            "sombrancelhas": Self.normalizedHex(eyebrows) ?? Self.vlibrasColors.eyebrows,
            "logo": logoURL,
            "pos": logoPosition.rawValue,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Mudanças que o JSON não consegue desfazer (voltar à logo ou às cores originais)
    /// exigem recarregar o player.
    public func needsReload(comparedTo previous: AvatarAppearance) -> Bool {
        if previous.enabled && !enabled { return true }
        if enabled, previous.enabled, previous.logoMode != .vlibras, logoMode == .vlibras { return true }
        return false
    }

    /// `#RGB`, `RRGGBB`, `#rrggbb` → `#RRGGBB`. Nil se inválido.
    public static func normalizedHex(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex
    }

    // Decodificação tolerante: campos novos não quebram preferências salvas.
    public init(from decoder: Decoder) throws {
        let d = AvatarAppearance()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        hair = try c.decodeIfPresent(String.self, forKey: .hair) ?? d.hair
        eyebrows = try c.decodeIfPresent(String.self, forKey: .eyebrows) ?? d.eyebrows
        skin = try c.decodeIfPresent(String.self, forKey: .skin) ?? d.skin
        iris = try c.decodeIfPresent(String.self, forKey: .iris) ?? d.iris
        eyes = try c.decodeIfPresent(String.self, forKey: .eyes) ?? d.eyes
        shirt = try c.decodeIfPresent(String.self, forKey: .shirt) ?? d.shirt
        pants = try c.decodeIfPresent(String.self, forKey: .pants) ?? d.pants
        logoMode = (try? c.decodeIfPresent(LogoMode.self, forKey: .logoMode)) ?? d.logoMode
        logoPosition = (try? c.decodeIfPresent(LogoPosition.self, forKey: .logoPosition)) ?? d.logoPosition
        logoScale = try c.decodeIfPresent(Double.self, forKey: .logoScale) ?? d.logoScale
        logoOffsetX = try c.decodeIfPresent(Double.self, forKey: .logoOffsetX) ?? d.logoOffsetX
        logoOffsetY = try c.decodeIfPresent(Double.self, forKey: .logoOffsetY) ?? d.logoOffsetY
        logoSourceFile = try c.decodeIfPresent(String.self, forKey: .logoSourceFile)
    }
}

/// Posiciona a logo no quadro de 500 × 500 que o player espera (área segura de 350 × 350).
public enum LogoLayout {
    public static let canvas = 500.0
    public static let margin = 75.0

    /// Retângulo (origem no canto inferior esquerdo) onde desenhar uma imagem de `size`.
    public static func frame(for size: CGSize, scale: Double, offsetX: Double, offsetY: Double) -> CGRect {
        let safe = canvas - 2 * margin
        guard size.width > 0, size.height > 0 else { return .zero }
        let clampedScale = min(1, max(0.3, scale))
        let fit = min(safe / size.width, safe / size.height) * clampedScale
        let width = size.width * fit
        let height = size.height * fit
        let freeX = (safe - width) / 2
        let freeY = (safe - height) / 2
        let x = margin + freeX + freeX * min(1, max(-1, offsetX))
        let y = margin + freeY + freeY * min(1, max(-1, offsetY))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Alteração parcial da aparência (API local, automações). Campos ausentes não mudam.
public struct AvatarAppearancePatch: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var hair: String?
    public var eyebrows: String?
    public var skin: String?
    public var iris: String?
    public var eyes: String?
    public var shirt: String?
    public var pants: String?
    public var logoMode: AvatarAppearance.LogoMode?
    public var logoPosition: AvatarAppearance.LogoPosition?
    public var logoScale: Double?
    public var logoOffsetX: Double?
    public var logoOffsetY: Double?

    public init() {}

    /// Aplica o que for válido; cores inválidas são ignoradas.
    public func applied(to appearance: AvatarAppearance) -> AvatarAppearance {
        var result = appearance
        func color(_ value: String?, _ keyPath: WritableKeyPath<AvatarAppearance, String>) {
            if let value, let hex = AvatarAppearance.normalizedHex(value) { result[keyPath: keyPath] = hex }
        }
        if let enabled { result.enabled = enabled }
        color(hair, \.hair)
        color(eyebrows, \.eyebrows)
        color(skin, \.skin)
        color(iris, \.iris)
        color(eyes, \.eyes)
        color(shirt, \.shirt)
        color(pants, \.pants)
        if let logoMode { result.logoMode = logoMode }
        if let logoPosition { result.logoPosition = logoPosition }
        if let logoScale { result.logoScale = min(1, max(0.3, logoScale)) }
        if let logoOffsetX { result.logoOffsetX = min(1, max(-1, logoOffsetX)) }
        if let logoOffsetY { result.logoOffsetY = min(1, max(-1, logoOffsetY)) }
        return result
    }
}
