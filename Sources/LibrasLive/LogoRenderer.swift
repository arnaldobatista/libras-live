import AppKit
import LibrasCore

/// Prepara a logo no formato que o player do VLibras espera: PNG 500 × 500, fundo
/// transparente e margem de 75 px, com tamanho e posição ajustáveis dentro da área segura.
enum LogoRenderer {
    struct Output {
        let png: Data
        /// Cantos da imagem original opacos: provavelmente tem fundo (fica um quadrado na camisa).
        let hasOpaqueBackground: Bool
    }

    enum RenderError: LocalizedError {
        case missingFile
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .missingFile: "O arquivo original da logo não foi encontrado. Escolha a imagem de novo para ajustar tamanho e posição."
            case .unreadableImage: "Não foi possível ler a imagem da logo."
            }
        }
    }

    static func render(sourceURL: URL, scale: Double, offsetX: Double, offsetY: Double) throws -> Output {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw RenderError.missingFile }
        guard let image = NSImage(contentsOf: sourceURL),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RenderError.unreadableImage
        }

        let frame = LogoLayout.frame(
            for: CGSize(width: source.width, height: source.height),
            scale: scale,
            offsetX: offsetX,
            offsetY: offsetY
        )
        let side = Int(LogoLayout.canvas)
        guard let context = makeContext(width: side, height: side) else { throw RenderError.unreadableImage }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.draw(source, in: frame)

        guard let rendered = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
            throw RenderError.unreadableImage
        }
        return Output(png: png, hasOpaqueBackground: cornersAreOpaque(source))
    }

    /// PNG 500 × 500 totalmente transparente (camisa sem logo).
    static func blankPNG() -> Data {
        let side = Int(LogoLayout.canvas)
        guard let context = makeContext(width: side, height: side),
              let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func cornersAreOpaque(_ image: CGImage) -> Bool {
        let side = 64
        guard let context = makeContext(width: side, height: side), let data = context.data else { return false }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let corners = [(1, 1), (side - 2, 1), (1, side - 2), (side - 2, side - 2)]
        return corners.allSatisfy { x, y in pixels[(y * side + x) * 4 + 3] > 240 }
    }
}
