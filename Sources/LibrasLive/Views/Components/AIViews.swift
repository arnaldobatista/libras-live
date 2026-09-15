import LibrasCore
import LocalAI
import SwiftUI

extension RewriteMode {
    var title: String {
        switch self {
        case .faithful: "Fiel"
        case .balanced: "Intermediário"
        case .rewrite: "Nova versão"
        }
    }

    var summary: String {
        switch self {
        case .faithful: "Corrige a transcrição e completa lacunas. Mantém as palavras e a ordem."
        case .balanced: "Corrige, completa e tira repetições e muletas. Mantém o sentido."
        case .rewrite: "Reescreve em frases curtas e diretas, fáceis de sinalizar."
        }
    }

    var symbol: String {
        switch self {
        case .faithful: "text.quote"
        case .balanced: "text.badge.checkmark"
        case .rewrite: "wand.and.sparkles"
        }
    }
}

extension PhraseRewriter.Result.Status {
    var title: String {
        switch self {
        case .rewritten: "Mudou"
        case .unchanged: "Mesmas palavras"
        case .fallback: "Ficou o original"
        }
    }

    var color: Color {
        switch self {
        case .rewritten: .accentColor
        case .unchanged: .secondary
        case .fallback: .orange
        }
    }
}

/// Três cartões para escolher quanto a IA pode mexer.
struct RewriteModePicker: View {
    @Binding var selection: RewriteMode

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { cards }
            VStack(spacing: 8) { cards }
        }
        .padding(.vertical, 4)
    }

    private var cards: some View {
        ForEach(RewriteMode.allCases) { mode in
            let isSelected = selection == mode
            Button {
                selection = mode
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbol)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(mode.title)
                            .font(.headline)
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(mode.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 140, idealWidth: 170, maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.fill.quaternary))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 1)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// Progresso de download com velocidade e botão de cancelar.
struct ModelDownloadProgress: View {
    let download: LocalAIController.Download
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = download.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Cancelar download")
            .accessibilityLabel("Cancelar download")
        }
        .frame(minWidth: 160, maxWidth: 260)
    }

    private var detail: String {
        guard download.total > 0 else { return download.status }
        let done = ByteCountFormatter.string(fromByteCount: download.completed, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: download.total, countStyle: .file)
        var text = "\(download.status) \(done) de \(total)"
        if download.bytesPerSecond > 0 {
            text += " · " + ByteCountFormatter.string(fromByteCount: Int64(download.bytesPerSecond), countStyle: .file) + "/s"
        }
        return text
    }
}

/// Modelo recomendado: por que, quanto pesa neste Mac e botão de baixar/usar.
struct RecommendationRow: View {
    @Environment(AppModel.self) private var model
    let recommendation: ModelCatalog.Recommendation

    var body: some View {
        let ai = model.localAI
        let fit = ModelCatalog.fit(memoryGB: recommendation.memoryGB, on: ai.machine)

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(recommendation.title)
                        .font(.headline)
                    Text(recommendation.badge.rawValue)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(recommendation.badge == .recommended ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background(recommendation.badge == .recommended ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                }
                Text(recommendation.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { facts(fit) }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) { facts(fit, range: 0..<2) }
                        HStack(spacing: 10) { facts(fit, range: 2..<4) }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func facts(_ fit: ModelCatalog.Fit, range: Range<Int> = 0..<4) -> some View {
        ForEach(range, id: \.self) { index in
            switch index {
            case 0: Label(String(format: "%.1f GB", recommendation.downloadGB), systemImage: "arrow.down.circle")
            case 1: Label(String(format: "%.1f GB de memória", recommendation.memoryGB), systemImage: "memorychip")
            case 2: Label(String(format: "~%.1f s por frase", recommendation.secondsPerPhrase), systemImage: "timer")
            default: fitLabel(fit)
            }
        }
    }

    @ViewBuilder
    private func fitLabel(_ fit: ModelCatalog.Fit) -> some View {
        switch fit {
        case .great: Label("Cabe bem neste Mac", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .tight: Label("Apertado com o OBS", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .tooBig: Label("Pesado para este Mac", systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var action: some View {
        let ai = model.localAI
        let name = recommendation.name
        if let download = ai.downloads[name] {
            ModelDownloadProgress(download: download) { ai.cancelDownload(name) }
        } else if ai.isInstalled(name) {
            if model.settings.rewrite.model.map({ ModelCatalog.sameModel($0, name) }) == true {
                Label("Em uso", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.callout.weight(.medium))
            } else {
                Button("Usar") { model.settings.rewrite.model = name }
                    .buttonStyle(.glass)
            }
        } else {
            Button("Baixar", systemImage: "arrow.down") { ai.download(name) }
                .buttonStyle(.glassProminent)
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Modelo instalado: detalhes, se está em uso ou na memória, e ações.
struct InstalledModelRow: View {
    @Environment(AppModel.self) private var model
    let installed: InstalledModel
    let onDelete: () -> Void

    var body: some View {
        let ai = model.localAI
        let inUse = model.settings.rewrite.model.map { ModelCatalog.sameModel($0, installed.name) } == true
        let loaded = ai.isLoaded(installed.name)

        HStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.title3)
                .foregroundStyle(inUse ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(installed.name)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                    if inUse { Pill(text: "Em uso", highlighted: true) }
                    if loaded { Pill(text: "Na memória", highlighted: false) }
                    if ai.warmingModel == installed.name { ProgressView().controlSize(.mini) }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Usar para reescrever", systemImage: "checkmark.circle") { model.settings.rewrite.model = installed.name }
                    .disabled(inUse)
                if loaded {
                    Button("Tirar da memória", systemImage: "eject") { Task { await ai.unload(installed.name) } }
                } else {
                    Button("Carregar agora", systemImage: "bolt") { Task { await ai.warmUp(installed.name) } }
                }
                Divider()
                Button("Excluir…", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Ações do modelo")
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts: [String] = []
        if let parameters = installed.details?.parameterSize { parts.append(parameters) }
        if let quantization = installed.details?.quantizationLevel { parts.append(quantization) }
        parts.append(ByteCountFormatter.string(fromByteCount: installed.size, countStyle: .file))
        if installed.capabilities?.contains("vision") == true { parts.append("imagem") }
        if installed.capabilities?.contains("thinking") == true { parts.append("raciocínio (desligado)") }
        return parts.joined(separator: " · ")
    }
}

struct Pill: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(highlighted ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.fill.tertiary), in: .capsule)
    }
}

/// Resultado de um modo no teste.
struct RewriteTestRow: View {
    let run: LocalAIController.TestRun

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: run.mode.symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(run.mode.title)
                        .font(.headline)
                    Spacer()
                    if let result = run.result {
                        Text(String(format: "%.2f s", result.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Pill(text: result.status.title, highlighted: result.status == .rewritten)
                    }
                }
                if run.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reescrevendo…").foregroundStyle(.secondary)
                    }
                } else if let result = run.result {
                    Text(result.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = result.reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
