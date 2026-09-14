import LibrasCore
import SwiftUI

struct LogsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Toggle("Gravar log da sessão", isOn: $model.settings.logEnabled)
                LabeledContent("Arquivo") {
                    Text(model.sessionLog.fileURL.lastPathComponent)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Eventos", value: "\(model.logEventCount)")

                if let summary = model.currentSummary, summary.dispatched + summary.dropped > 0 {
                    SummaryGrid(summary: summary)
                        .padding(.vertical, 6)
                }

                HStack {
                    Button("Salvar log…", systemImage: "square.and.arrow.down") { model.exportLog() }
                        .buttonStyle(.glassProminent)
                    Button("Abrir pasta", systemImage: "folder") { model.openLogsFolder() }
                        .buttonStyle(.glass)
                    Spacer()
                    Button {
                        model.refreshLogs()
                    } label: {
                        Label("Atualizar", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Atualizar resumo")
                }
            } header: {
                Text("Sessão atual")
            } footer: {
                Text("Salvar gera um .txt legível (resumo e linha do tempo) e um .jsonl completo para análise.")
            }

            Section("Sessões anteriores") {
                let previous = model.sessionFiles.filter { !$0.isCurrent }
                if previous.isEmpty {
                    Text("Nenhuma sessão anterior.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(previous) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.date, format: .dateTime.day().month(.wide).year().hour().minute())
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Salvar…") { model.exportLog(file: file) }
                                .buttonStyle(.borderless)
                            Button {
                                model.revealInFinder(file.url)
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Mostrar no Finder")
                        }
                        .contextMenu {
                            Button("Salvar…") { model.exportLog(file: file) }
                            Button("Mostrar no Finder") { model.revealInFinder(file.url) }
                        }
                    }
                }
            }

            Section {
                Button("Apagar todos os logs…", role: .destructive) { confirmClear = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshLogs() }
        .confirmationDialog("Apagar todos os logs?", isPresented: $confirmClear) {
            Button("Apagar logs", role: .destructive) { model.clearLogs() }
        } message: {
            Text("Os arquivos de todas as sessões serão removidos. Um log novo começa em seguida.")
        }
    }
}

private struct SummaryGrid: View {
    let summary: SessionLogFormatter.Summary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { tiles(0..<4) }
            VStack(spacing: 8) {
                HStack(spacing: 8) { tiles(0..<2) }
                HStack(spacing: 8) { tiles(2..<4) }
            }
        }
    }

    @ViewBuilder
    private func tiles(_ range: Range<Int>) -> some View {
        let total = summary.dispatched + summary.dropped
        let waits = summary.queueWaits
        ForEach(range, id: \.self) { index in
            switch index {
            case 0:
                MetricTile(title: "Sinalizadas", value: "\(summary.dispatched)", symbol: "hand.wave")
            case 1:
                MetricTile(
                    title: "Descartadas",
                    value: "\(summary.dropped)",
                    detail: total > 0 ? String(format: "%.0f%%", summary.dropRate * 100) : nil,
                    symbol: "xmark.circle",
                    tint: summary.dropRate > 0.15 ? .orange : .primary
                )
            case 2:
                MetricTile(
                    title: "Espera média",
                    value: waits.isEmpty ? "—" : String(format: "%.1f", waits.reduce(0, +) / Double(waits.count)),
                    detail: waits.isEmpty ? nil : "s",
                    symbol: "timer"
                )
            default:
                MetricTile(
                    title: "Velocidade",
                    value: summary.speeds.isEmpty ? "—" : String(format: "%.1f", summary.speeds.reduce(0, +) / Double(summary.speeds.count)),
                    detail: summary.speeds.isEmpty ? nil : "×",
                    symbol: "gauge.with.dots.needle.67percent"
                )
            }
        }
    }
}
