import SwiftUI

/// Janela de Ajustes (⌘,): preferências gerais do app.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Geral", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Sobre", systemImage: "info.circle") {
                AboutSettings()
            }
        }
        .frame(width: 520, height: 380)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
