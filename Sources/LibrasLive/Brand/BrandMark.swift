import SwiftUI

/// Marca do Libras Live: mão aberta (Libras) com ondas de transmissão (ao vivo).
///
/// Desenho original e vetorial, usado no app e para gerar as camadas do ícone
/// (Scripts/render-icon.swift). Coordenadas num quadro de 100 × 100, eixo y para baixo.
enum Brand {
    /// Cor base da marca (índigo) e destaque "ao vivo".
    static let indigo = Color(red: 0.36, green: 0.33, blue: 0.95)
    static let violet = Color(red: 0.55, green: 0.32, blue: 0.96)
    static let cyan = Color(red: 0.20, green: 0.66, blue: 0.98)
    static let live = Color(red: 1.0, green: 0.30, blue: 0.33)

    static let gradient = LinearGradient(
        colors: [violet, indigo, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Mão aberta estilizada: palma arredondada, quatro dedos em cápsula e polegar, unidos numa só forma.
struct BrandHandShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 100
        let origin = CGPoint(x: rect.midX - 50 * unit, y: rect.midY - 50 * unit)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }
        func capsule(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGPath {
            let line = CGMutablePath()
            line.move(to: start)
            line.addLine(to: end)
            return line.copy(strokingWithWidth: width * unit, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }

        var hand = CGPath(
            roundedRect: CGRect(origin: p(30, 46), size: CGSize(width: 40 * unit, height: 39 * unit)),
            cornerWidth: 17 * unit,
            cornerHeight: 17 * unit,
            transform: nil
        )
        // Dedos: indicador, médio, anelar, mínimo.
        let fingers: [(x: CGFloat, top: CGFloat)] = [(35.4, 22.5), (45.3, 15.5), (55.2, 17.5), (64.8, 26.5)]
        for finger in fingers {
            hand = hand.union(capsule(from: p(finger.x, 58), to: p(finger.x, finger.top), width: 9.2))
        }
        // Polegar.
        hand = hand.union(capsule(from: p(39, 72), to: p(23.5, 52), width: 9.8))
        return Path(hand)
    }
}

/// Ondas de transmissão simétricas, dos dois lados da mão.
struct BrandWavesShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 100
        let center = CGPoint(x: rect.midX, y: rect.midY + 3 * unit)
        let waves = CGMutablePath()
        for radius: CGFloat in [36, 46] {
            for (start, end) in [(-38.0, 38.0), (142.0, 218.0)] {
                let arc = CGMutablePath()
                arc.addArc(center: center, radius: radius * unit, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
                waves.addPath(arc.copy(strokingWithWidth: 4.9 * unit, lineCap: .round, lineJoin: .round, miterLimit: 1))
            }
        }
        return Path(waves)
    }
}

/// Ícone do app desenhado em SwiftUI (cabeçalhos, boas-vindas, sobre).
struct BrandIcon: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Brand.gradient)
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(.linearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            Group {
                BrandWavesShape().fill(.white.opacity(0.72))
                BrandHandShape().fill(.white)
            }
            .padding(size * 0.12)
            .shadow(color: .black.opacity(0.18), radius: size * 0.02, y: size * 0.012)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
