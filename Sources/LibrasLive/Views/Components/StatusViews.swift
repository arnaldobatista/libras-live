import SwiftUI

/// Ponto de "ao vivo" que pulsa enquanto ouve.
struct LiveIndicator: View {
    let isLive: Bool

    var body: some View {
        Circle()
            .fill(isLive ? Color.red : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
            .overlay {
                if isLive {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 2)
                        .scaleEffect(1.8)
                        .opacity(0.8)
                        .phaseAnimator([false, true]) { view, phase in
                            view.scaleEffect(phase ? 1.4 : 0.8).opacity(phase ? 0 : 0.8)
                        } animation: { _ in .easeOut(duration: 1.2) }
                }
            }
            .accessibilityLabel(isLive ? "Ouvindo" : "Parado")
    }
}

/// Cápsula de status em vidro (sobre conteúdo, como a prévia do avatar).
struct StatusChip: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary
    /// Só o símbolo (espaços pequenos); o texto vira dica e rótulo de acessibilidade.
    var iconOnly = false

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .labelStyle(iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
            .padding(.horizontal, iconOnly ? 6 : 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .help(title)
            .fixedSize()
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// Valor de destaque do painel ao vivo.
struct MetricTile: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String
    var tint: Color = .primary
    /// Versão sem ícone e com menos respiro, para larguras menores.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            Group {
                if compact {
                    Text(title)
                } else {
                    Label(title, systemImage: symbol)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(compact ? .title3 : .title2, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 8 : 12)
        .background(.fill.quinary, in: .rect(cornerRadius: compact ? 10 : 12))
        .accessibilityElement(children: .combine)
    }
}

/// Aviso em linha, com ação opcional (permissões, erros recuperáveis).
struct Callout: View {
    enum Kind { case info, warning, error }

    let kind: Kind
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dispensar")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.10), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.25)))
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

extension View {
    /// Cartão de conteúdo padrão (camada de conteúdo, sem vidro).
    func contentCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
    }
}
