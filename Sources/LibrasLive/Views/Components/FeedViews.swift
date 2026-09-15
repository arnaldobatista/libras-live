import LibrasCore
import LocalAI
import SwiftUI

extension FeedEntry.Status {
    var title: String {
        switch self {
        case .translating: "Traduzindo"
        case .queued: "Na fila"
        case .playing: "Sinalizando"
        case .played: "Sinalizado"
        case .dropped: "Descartado"
        }
    }

    var symbol: String {
        switch self {
        case .translating: "ellipsis.circle"
        case .queued: "clock"
        case .playing: "hand.wave.fill"
        case .played: "checkmark.circle.fill"
        case .dropped: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .translating: .secondary
        case .queued: .blue
        case .playing: .green
        case .played: .secondary
        case .dropped: .orange
        }
    }
}

/// Linha do histórico: status, frase, glosa sinalizada e detalhes discretos.
struct FeedRow: View {
    let entry: FeedEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.status.symbol)
                .font(.body)
                .foregroundStyle(entry.status.color)
                .symbolEffect(.pulse, isActive: entry.status == .playing)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityLabel(entry.status.title)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .strikethrough(entry.status == .dropped, color: .secondary)
                    .foregroundStyle(entry.status == .dropped ? .secondary : .primary)
                    .lineLimit(3)

                if let rewrite = entry.rewrite, rewrite.status == .rewritten, rewrite.result.hasPrefix(entry.text) {
                    Text("Falado: \(rewrite.original)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                if let gloss = entry.signed ?? entry.gloss {
                    Text(gloss.isEmpty ? "—" : gloss)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    if entry.status == .dropped, let reason = entry.dropReason {
                        Tag(text: reason, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if entry.source == .fallback {
                        Tag(text: "sem tradução", symbol: "character.bubble", tint: .red)
                    }
                    if let rewrite = entry.rewrite {
                        switch rewrite.status {
                        case .rewritten:
                            Tag(text: "IA · \(rewrite.mode.title.lowercased())", symbol: "sparkles", tint: .accentColor)
                        case .unchanged:
                            Tag(text: "IA · ok", symbol: "sparkles")
                                .help("A IA manteve as palavras (só pontuação ou maiúsculas)")
                        case .fallback:
                            Tag(text: "original", symbol: "sparkles", tint: .orange)
                                .help(rewrite.reason ?? "")
                        }
                    }
                    if let speed = entry.speed, speed > 1.01 {
                        Tag(text: String(format: "%.1f×", speed), symbol: "hare")
                    }
                    if entry.batchSize > 1 {
                        Tag(text: "+\(entry.batchSize - 1) no envio", symbol: "square.stack")
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Etiqueta discreta; cor só para o que pede atenção (descarte, falta de tradução).
private struct Tag: View {
    let text: String
    let symbol: String
    var tint: Color?

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(TagLabelStyle())
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.map { AnyShapeStyle($0.opacity(0.16)) } ?? AnyShapeStyle(.fill.tertiary), in: .capsule)
    }
}

private struct TagLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Detalhes da frase selecionada (inspetor).
struct FeedInspector: View {
    let entry: FeedEntry?

    var body: some View {
        if let entry {
            Form {
                Section("Frase") {
                    Text(entry.text).textSelection(.enabled)
                    LabeledContent("Status") {
                        Label(entry.status.title, systemImage: entry.status.symbol)
                            .foregroundStyle(entry.status.color)
                    }
                    LabeledContent("Horário", value: entry.date.formatted(date: .omitted, time: .standard))
                    if let reason = entry.dropReason {
                        LabeledContent("Motivo", value: reason)
                    }
                }
                if let rewrite = entry.rewrite {
                    Section("Reescrita com IA") {
                        LabeledContent("Falado") {
                            Text(rewrite.original).textSelection(.enabled)
                        }
                        if rewrite.status == .rewritten {
                            LabeledContent("Reescrito") {
                                Text(rewrite.result).textSelection(.enabled)
                            }
                        }
                        LabeledContent("Resultado", value: rewrite.reason.map { "\(rewrite.status.title): \($0)" } ?? rewrite.status.title)
                        LabeledContent("Modo", value: rewrite.mode.title)
                        LabeledContent("Modelo", value: rewrite.model)
                        LabeledContent("Tempo da IA", value: String(format: "%.2f s", rewrite.seconds))
                        LabeledContent("Espera pelo fim da frase", value: String(format: "%.1f s", rewrite.waited))
                    }
                }
                Section("Glosa") {
                    if let gloss = entry.gloss {
                        LabeledContent("Tradutor") {
                            Text(gloss).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if let signed = entry.signed {
                        LabeledContent("Sinalizado") {
                            Text(signed.isEmpty ? "—" : signed).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if let source = entry.source {
                        LabeledContent("Origem", value: source == .cache ? "Cache" : (source == .remote ? "API do VLibras" : "Sem tradução"))
                    }
                }
                if !entry.removed.isEmpty || !entry.replaced.isEmpty {
                    Section("Ajustes na glosa") {
                        if !entry.replaced.isEmpty {
                            LabeledContent("Trocados", value: entry.replaced.joined(separator: "\n"))
                        }
                        if !entry.removed.isEmpty {
                            LabeledContent("Removidos", value: entry.removed.joined(separator: " "))
                        }
                    }
                }
                Section("Envio") {
                    LabeledContent("Velocidade", value: entry.speed.map { String(format: "%.2f×", $0) } ?? "—")
                    LabeledContent("Frases no envio", value: "\(entry.batchSize)")
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Nenhuma frase selecionada", systemImage: "text.bubble", description: Text("Selecione uma frase do histórico para ver a glosa e os ajustes."))
        }
    }
}
