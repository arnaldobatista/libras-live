// Gera as camadas do ícone (Icon Composer) a partir das formas de Brand/BrandMark.swift.
//
//   swiftc -parse-as-library Sources/LibrasLive/Brand/BrandMark.swift Scripts/render-icon.swift -o /tmp/render-icon
//   /tmp/render-icon Resources/AppIcon.icon [prévia.png]
//
// Saída: <pasta>.icon/icon.json + Assets/hand.png e waves.png (1024 × 1024, transparentes).

import AppKit
import SwiftUI

@main
struct RenderIcon {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("Uso: render-icon <saida.icon> [previa.png]")
            exit(1)
        }
        let iconURL = URL(fileURLWithPath: arguments[1])
        let assets = iconURL.appendingPathComponent("Assets")
        try? FileManager.default.removeItem(at: iconURL)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        // O conteúdo ocupa ~72% do quadro, centralizado (grade de ícones do macOS).
        let canvas: CGFloat = 1024
        let glyph = canvas * 0.72
        func layer<S: Shape>(_ shape: S, color: Color) -> some View {
            shape.fill(color)
                .frame(width: glyph, height: glyph)
                .frame(width: canvas, height: canvas)
        }

        try write(layer(BrandHandShape(), color: .white), to: assets.appendingPathComponent("hand.png"))
        try write(layer(BrandWavesShape(), color: .white), to: assets.appendingPathComponent("waves.png"))

        let json = """
        {
          "fill" : {
            "automatic-gradient" : "extended-srgb:0.36000,0.33000,0.95000,1.00000"
          },
          "groups" : [
            {
              "layers" : [
                {
                  "fill" : { "solid" : "extended-gray:1.00000,1.00000" },
                  "glass" : true,
                  "image-name" : "hand.png",
                  "name" : "hand",
                  "position" : { "scale" : 1, "translation-in-points" : [0, 0] }
                }
              ],
              "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
              "translucency" : { "enabled" : true, "value" : 0.3 }
            },
            {
              "layers" : [
                {
                  "fill" : { "solid" : "extended-gray:1.00000,1.00000" },
                  "glass" : true,
                  "image-name" : "waves.png",
                  "name" : "waves",
                  "position" : { "scale" : 1, "translation-in-points" : [0, 0] }
                }
              ],
              "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
              "translucency" : { "enabled" : true, "value" : 0.6 }
            }
          ],
          "supported-platforms" : {
            "squares" : [ "macOS" ]
          }
        }
        """
        try json.write(to: iconURL.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)

        if arguments.count >= 3 {
            try write(BrandIcon(size: 512).padding(20).background(Color(white: 0.93)), to: URL(fileURLWithPath: arguments[2]))
        }
        print("OK: \(iconURL.path)")
    }

    @MainActor
    static func write<V: View>(_ view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "render-icon", code: 1)
        }
        try png.write(to: url)
    }
}
