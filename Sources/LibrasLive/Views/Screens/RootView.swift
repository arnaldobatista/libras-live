import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(NavigationModel.self) private var navigation
    @AppStorage("LibrasLive.onboardingCompleted") private var onboardingCompleted = false
    @State private var showOnboarding = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var navigation = navigation
        let selection = navigation.section

        NavigationSplitView {
            Sidebar(selection: $navigation.section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            detail
                .navigationTitle((selection ?? .live).title)
                .navigationSubtitle(subtitle)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                onboardingCompleted = true
                showOnboarding = false
            }
            .environment(model)
            .interactiveDismissDisabled()
        }
        .onAppear {
            // Quem já usava o app antes das boas-vindas existirem não precisa passar por elas
            // (se a chave já existe, é escolha do usuário, como "Mostrar as boas-vindas de novo").
            if UserDefaults.standard.object(forKey: "LibrasLive.onboardingCompleted") == nil, !model.isFirstRun {
                onboardingCompleted = true
            }
            showOnboarding = !onboardingCompleted || ProcessInfo.processInfo.environment["LIBRAS_ONBOARDING"] == "1"
            if ProcessInfo.processInfo.environment["LIBRAS_OPEN_SETTINGS"] == "1" { openSettings() }
            if UserDefaults.standard.object(forKey: "LibrasLive.showAvatarPreview") as? Bool ?? true {
                AvatarPreviewHost.shared.preload(model.previewURL)
            }
            // LIBRAS_SECTION_TOUR="audio:3,live:3": troca de tela sozinha (testes de interface).
            if let tour = ProcessInfo.processInfo.environment["LIBRAS_SECTION_TOUR"] {
                let steps = tour.split(separator: ",").compactMap { step -> (AppSection, Double)? in
                    let parts = step.split(separator: ":")
                    guard let section = parts.first.flatMap({ AppSection(rawValue: String($0)) }) else { return nil }
                    return (section, parts.count > 1 ? Double(parts[1]) ?? 3 : 3)
                }
                Task {
                    for (section, seconds) in steps {
                        try? await Task.sleep(for: .seconds(seconds))
                        navigation.section = section
                    }
                }
            }
            if let size = ProcessInfo.processInfo.environment["LIBRAS_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 700 }),
                          let screen = window.screen else { return }
                    let visible = screen.visibleFrame
                    window.setFrame(NSRect(x: visible.minX + 40, y: visible.maxY - size[1], width: size[0], height: size[1]), display: true)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section ?? .live {
        case .live: LiveScreen()
        case .audio: AudioScreen()
        case .avatar: AvatarScreen()
        case .obs: OBSScreen()
        case .translation: TranslationScreen()
        case .ai: AIScreen()
        case .logs: LogsScreen()
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append(model.isListening ? "Ouvindo" : (model.isStartingListening ? "Iniciando…" : "Parado"))
        let visible = model.overlayReady - model.overlayHidden
        parts.append(visible > 0 ? "OBS conectado" : "OBS aguardando")
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.clearQueue()
            } label: {
                Label("Limpar fila", systemImage: "xmark.bin")
            }
            .help("Limpar a fila e parar o avatar (⌘K)")
            .disabled(model.snapshot.queued == 0 && model.snapshot.playingID == nil)

            Menu {
                Button("Copiar URL do overlay", systemImage: "link") { model.copyOverlayURL() }
                Button("Abrir overlay no navegador", systemImage: "safari") { model.openOverlayInBrowser() }
                Divider()
                Button("Salvar log da sessão…", systemImage: "square.and.arrow.down") { model.exportLog() }
                Button("Abrir pasta de logs", systemImage: "folder") { model.openLogsFolder() }
            } label: {
                Label("Mais ações", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("Mais ações")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.toggleListening()
            } label: {
                Label(listenTitle, systemImage: model.isListening ? "stop.fill" : "mic.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .tint(model.isListening ? .red : .accentColor)
            .disabled(model.isStartingListening)
            .help(model.isListening ? "Parar de ouvir (⌘L)" : "Começar a ouvir o canal escolhido (⌘L)")
        }
    }

    private var listenTitle: String {
        if model.isStartingListening { return "Iniciando…" }
        return model.isListening ? "Parar" : "Começar"
    }
}

/// Barra lateral com as telas e o status da transmissão.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: AppSection?

    var body: some View {
        List(selection: $selection) {
            Section("Transmissão") {
                ForEach(AppSection.broadcast) { row($0) }
            }
            Section("Ajustes") {
                ForEach(AppSection.tuning) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarStatus()
                .padding(10)
        }
    }

    @ViewBuilder
    private func row(_ section: AppSection) -> some View {
        // A tag precisa vir depois do badge (e sem Optional explícito), senão a seleção não aparece.
        Label(section.title, systemImage: section.symbol)
            .badge(badge(for: section))
            .tag(section)
    }

    private func badge(for section: AppSection) -> Text? {
        switch section {
        case .live where model.snapshot.queued > 0:
            Text("\(model.snapshot.queued)")
        case .audio where model.captureWarning != nil:
            Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundColor(.orange)
        case .obs where model.overlayReady > model.overlayHidden:
            Text(Image(systemName: "checkmark.circle.fill")).foregroundColor(.green)
        case .ai where model.settings.rewrite.enabled:
            model.rewritePending > 0 ? Text("\(model.rewritePending)") : Text("ligada")
        default:
            nil
        }
    }
}

private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            BrandIcon(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Libras Live")
                    .font(.callout.weight(.semibold))
                HStack(spacing: 6) {
                    LiveIndicator(isLive: model.isListening)
                    Text(model.isListening ? "Ouvindo" : "Parado")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
