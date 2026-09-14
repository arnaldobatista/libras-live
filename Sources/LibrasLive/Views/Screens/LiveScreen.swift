import SwiftUI

/// Painel da transmissão: métricas, fala atual, histórico e avatar ao vivo.
///
/// O layout depende da largura disponível (janela, barra lateral e inspetor):
/// avatar em coluna ao lado, avatar menor ao lado da fala, ou só o essencial.
struct LiveScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("LibrasLive.showAvatarPreview") private var showPreview = true
    @State private var selectedEntry: FeedEntry.ID?
    @State private var showInspector = false

    var body: some View {
        GeometryReader { proxy in
            let layout = LiveLayout(width: proxy.size.width)
            content(layout)
                .padding(layout.padding)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .safeAreaInset(edge: .bottom) {
            ComposerBar()
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .inspector(isPresented: $showInspector) {
            FeedInspector(entry: model.feed.first { $0.id == selectedEntry })
                .inspectorColumnWidth(min: 240, ideal: 290, max: 360)
        }
        .onChange(of: selectedEntry) { _, entry in
            if entry != nil { showInspector = true }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Detalhes", systemImage: "sidebar.trailing")
                }
                .help("Mostrar detalhes da frase selecionada")
            }
        }
    }

    @ViewBuilder
    private func content(_ layout: LiveLayout) -> some View {
        switch layout.arrangement {
        case .columns(let avatarWidth):
            HStack(alignment: .top, spacing: layout.spacing) {
                VStack(spacing: layout.spacing) {
                    callouts
                    MetricsRow()
                    CaptionCard()
                    FeedPanel(selection: $selectedEntry)
                }
                AvatarPanel(showPreview: showPreview, style: .column)
                    .frame(width: avatarWidth)
            }
        case .beside(let avatarWidth):
            VStack(spacing: layout.spacing) {
                callouts
                HStack(alignment: .top, spacing: layout.spacing) {
                    VStack(spacing: layout.spacing) {
                        MetricsRow()
                        CaptionCard(fillsHeight: true)
                    }
                    AvatarPanel(showPreview: showPreview, style: .thumbnail)
                        .frame(width: avatarWidth)
                }
                .fixedSize(horizontal: false, vertical: true)
                FeedPanel(selection: $selectedEntry)
            }
        case .single:
            VStack(spacing: layout.spacing) {
                callouts
                MetricsRow()
                CaptionCard()
                FeedPanel(selection: $selectedEntry)
            }
        }
    }

    @ViewBuilder
    private var callouts: some View {
        if let error = model.errorMessage {
            Callout(kind: .error, message: error, onDismiss: { model.dismissError() })
        }
        if let warning = model.captureWarning {
            Callout(
                kind: .warning,
                message: warning,
                actionTitle: model.microphoneAuthorized ? nil : "Permitir microfone",
                action: model.microphoneAuthorized ? nil : { model.requestMicrophoneAccess() }
            )
        }
    }
}

/// Distribuição da tela Ao vivo conforme a largura disponível.
struct LiveLayout: Equatable {
    enum Arrangement: Equatable {
        /// Avatar numa coluna inteira à direita.
        case columns(avatarWidth: CGFloat)
        /// Avatar menor ao lado das métricas e da fala; histórico embaixo, na largura toda.
        case beside(avatarWidth: CGFloat)
        /// Sem avatar (espaço mínimo, por exemplo com o inspetor aberto).
        case single
    }

    let arrangement: Arrangement
    let padding: CGFloat
    let spacing: CGFloat

    init(width: CGFloat) {
        switch width {
        case 780...:
            arrangement = .columns(avatarWidth: (width * 0.3).rounded().clamped(to: 240...380))
            padding = 20
            spacing = 16
        case 470..<780:
            arrangement = .beside(avatarWidth: (width * 0.25).rounded().clamped(to: 118...170))
            padding = 14
            spacing = 12
        default:
            arrangement = .single
            padding = 12
            spacing = 10
        }
    }
}

private struct MetricsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // A primeira variante que couber na largura: cartões completos, compactos, 3 + 2 ou 2 + 2 + 1.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { tiles(compact: false) }
            HStack(spacing: 8) { tiles(compact: true) }
            VStack(spacing: 8) {
                HStack(spacing: 8) { tiles(compact: true, range: 0..<3) }
                HStack(spacing: 8) { tiles(compact: true, range: 3..<5) }
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) { tiles(compact: true, range: 0..<2) }
                HStack(spacing: 8) { tiles(compact: true, range: 2..<4) }
                HStack(spacing: 8) { tiles(compact: true, range: 4..<5) }
            }
        }
        .animation(.snappy, value: model.snapshot)
    }

    @ViewBuilder
    private func tiles(compact: Bool, range: Range<Int> = 0..<5) -> some View {
        let snapshot = model.snapshot
        let policy = model.settings.policy
        let total = snapshot.played + snapshot.dropped
        let dropRate = total == 0 ? 0 : Double(snapshot.dropped) / Double(total)

        ForEach(range, id: \.self) { index in
            switch index {
            case 0:
                MetricTile(
                    title: "Atraso",
                    value: String(format: "%.1f", snapshot.lag),
                    detail: "s",
                    symbol: "timer",
                    tint: snapshot.lag >= policy.dropAfter ? .red : (snapshot.lag >= policy.speedUpAfter ? .orange : .primary),
                    compact: compact
                )
            case 1:
                MetricTile(title: "Velocidade", value: String(format: "%.1f", snapshot.speed), detail: "×", symbol: "gauge.with.dots.needle.67percent", compact: compact)
            case 2:
                MetricTile(title: "Na fila", value: "\(snapshot.queued)", symbol: "tray.full", compact: compact)
            case 3:
                MetricTile(title: "Sinalizadas", value: "\(snapshot.played)", symbol: "hand.wave", compact: compact)
            default:
                MetricTile(
                    title: "Descartadas",
                    value: "\(snapshot.dropped)",
                    detail: total > 0 ? String(format: "%.0f%%", dropRate * 100) : nil,
                    symbol: "xmark.circle",
                    tint: dropRate > 0.15 ? .orange : .primary,
                    compact: compact
                )
            }
        }
    }
}

/// Fala reconhecida agora e a fonte de áudio.
private struct CaptionCard: View {
    @Environment(AppModel.self) private var model
    /// Estica até a altura da linha (ao lado do avatar menor).
    var fillsHeight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LiveIndicator(isLive: model.isListening)
                Text(model.isListening ? "Ouvindo agora" : "Pronto para ouvir")
                    .font(.headline)
                Spacer()
                VoiceIndicator(voiceDetected: model.voiceDetected, active: model.isListening)
            }

            Group {
                if !model.partialText.isEmpty {
                    Text(model.partialText)
                        .foregroundStyle(.primary)
                } else if model.isListening {
                    Text("Aguardando fala…")
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Escolha o canal em Áudio e clique em Começar.")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.title3)
            .lineLimit(3, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.15), value: model.partialText)

            HStack(spacing: 12) {
                Label(sourceDescription, systemImage: "mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if model.isCapturing {
                    LevelMeter(level: model.level, active: true)
                        .frame(maxWidth: 220)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.2), value: model.isCapturing)
        }
        .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
        .contentCard()
    }

    private var sourceDescription: String {
        guard let device = model.selectedDevice else { return "Nenhum dispositivo" }
        let channels = model.settings.channels.filter { $0 < device.inputChannels }.map { String($0 + 1) }
        return "\(device.name) · canal \(channels.joined(separator: " + "))"
    }
}

private struct FeedPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: FeedEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Histórico")
                    .font(.headline)
                Spacer()
                Text("\(model.feed.count) frases")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if model.feed.isEmpty {
                ContentUnavailableView(
                    "Nada traduzido ainda",
                    systemImage: "hands.and.sparkles",
                    description: Text("As frases aparecem aqui com a glosa enviada ao avatar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(model.feed, selection: $selection) { entry in
                        FeedRow(entry: entry)
                            .id(entry.id)
                            .tag(entry.id)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.feed.first?.id) { _, newest in
                        // A frase nova entra no topo; acompanha, a menos que alguém esteja inspecionando uma frase.
                        guard selection == nil, let newest else { return }
                        withAnimation(.snappy) { proxy.scrollTo(newest, anchor: .top) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Avatar ao vivo com status do OBS e troca rápida de personagem.
private struct AvatarPanel: View {
    enum Style { case column, thumbnail }

    @Environment(AppModel.self) private var model
    let showPreview: Bool
    let style: Style

    var body: some View {
        @Bindable var model = model
        let visible = model.overlayReady - model.overlayHidden

        VStack(spacing: 10) {
            AvatarStage(url: model.previewURL, enabled: showPreview, cornerRadius: style == .column ? 18 : 12) {
                VStack {
                    HStack {
                        StatusChip(
                            title: visible > 0 ? "OBS conectado" : "OBS aguardando",
                            symbol: visible > 0 ? "checkmark.circle.fill" : "circle.dashed",
                            tint: visible > 0 ? .green : .secondary,
                            iconOnly: style == .thumbnail
                        )
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    if style == .thumbnail {
                        HStack {
                            Spacer(minLength: 0)
                            avatarMenu
                        }
                    }
                }
                .padding(style == .column ? 10 : 6)
            }

            if style == .column {
                Picker("Personagem", selection: $model.settings.avatar) {
                    ForEach(Avatar.allCases) { avatar in
                        Text(avatar.title).tag(avatar)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var avatarMenu: some View {
        Menu {
            Picker("Personagem", selection: Binding(get: { model.settings.avatar }, set: { model.settings.avatar = $0 })) {
                ForEach(Avatar.allCases) { avatar in
                    Text(avatar.title).tag(avatar)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "person.2.fill")
                .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Trocar personagem")
        .accessibilityLabel("Trocar personagem")
    }
}

/// Barra flutuante para testar frases sem microfone.
private struct ComposerBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.cursor")
                .foregroundStyle(.secondary)
            TextField("Digite uma frase para testar o avatar", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Enviar frase de teste")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 640)
        .onReceive(NotificationCenter.default.publisher(for: .focusComposer)) { _ in focused = true }
    }

    private func send() {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        model.submitFinal(phrase)
        text = ""
    }
}

extension Notification.Name {
    static let focusComposer = Notification.Name("LibrasLive.focusComposer")
}
