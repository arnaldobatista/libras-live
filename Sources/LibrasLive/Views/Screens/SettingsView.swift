import SwiftUI

/// Janela de Ajustes (⌘,): preferências gerais do app.
struct SettingsView: View {
    /// `LIBRAS_SETTINGS_TAB=about` abre direto no Sobre (capturas de tela).
    @State private var tab = ProcessInfo.processInfo.environment["LIBRAS_SETTINGS_TAB"] ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Geral", systemImage: "gearshape", value: "general") {
                GeneralSettings()
            }
            Tab("Sobre", systemImage: "info.circle", value: "about") {
                AboutSettings()
            }
        }
        .frame(width: 520, height: 400)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(NavigationModel.self) private var navigation
    @AppStorage("LibrasLive.showAvatarPreview") private var showPreview = true
    @AppStorage("LibrasLive.onboardingCompleted") private var onboardingCompleted = true

    var body: some View {
        @Bindable var model = model
        @Bindable var navigation = navigation

        Form {
            Section("Janela") {
                Toggle("Mostrar prévia do avatar", isOn: $showPreview)
                Toggle("Mostrar ícone na barra de menus", isOn: $navigation.showMenuBarExtra)
            }
            Section("Logs") {
                Toggle("Gravar log das sessões", isOn: $model.settings.logEnabled)
            }
            Section {
                Button("Mostrar as boas-vindas de novo") { onboardingCompleted = false }
            } footer: {
                Text("As boas-vindas aparecem na próxima vez que a janela principal abrir.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            BrandIcon(size: 88)
            Text("Libras Live")
                .font(.title.weight(.semibold))
            Text("Versão \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Tradução automática de fala para Libras com o avatar do VLibras (LGPL-3.0). A tradução automática não substitui intérprete.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 10) {
                Link(destination: AppLinks.repository) {
                    Label("Código-fonte", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppLinks.newIssue) {
                    Label("Relatar um problema", systemImage: "exclamationmark.bubble")
                }
                Button("Licenças", systemImage: "doc.text") { AppLinks.openLicenses() }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .padding(.top, 4)

            Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "Licença MIT")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Endereços do projeto.
enum AppLinks {
    static let repository = URL(string: "https://github.com/arnaldobatista/libras-live")!
    static let newIssue = URL(string: "https://github.com/arnaldobatista/libras-live/issues/new/choose")!
    static let thirdPartyNotices = URL(string: "https://github.com/arnaldobatista/libras-live/blob/main/THIRD_PARTY_NOTICES.md")!

    /// Pasta com as licenças dentro do app; fora do .app (desenvolvimento), a lista no GitHub.
    @MainActor
    static func openLicenses() {
        if let folder = Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true),
           FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.open(thirdPartyNotices)
        }
    }
}
