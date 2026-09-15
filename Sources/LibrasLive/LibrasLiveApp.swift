import AppKit
import SwiftUI

@main
struct LibrasLiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppDelegate.model
    @State private var navigation = NavigationModel()

    var body: some Scene {
        Window("Libras Live", id: "main") {
            RootView()
                .environment(model)
                .environment(navigation)
                .frame(minWidth: 720, minHeight: 540)
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Transmissão") {
                Button(model.isListening ? "Parar de ouvir" : "Começar a ouvir") { model.toggleListening() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Limpar fila") { model.clearQueue() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Testar uma frase") {
                    navigation.section = .live
                    NotificationCenter.default.post(name: .focusComposer, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("Copiar URL do overlay") { model.copyOverlayURL() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Abrir overlay no navegador") { model.openOverlayInBrowser() }
                Divider()
                Button("Salvar log da sessão…") { model.exportLog() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Abrir pasta de logs") { model.openLogsFolder() }
            }

            CommandGroup(before: .sidebar) {
                SectionCommands(navigation: navigation)
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(navigation)
        }

        MenuBarExtra(isInserted: navigation.menuBarBinding) {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.isListening ? "hand.raised.fill" : "hand.raised")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let model = AppModel()
    private var terminationReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // LIBRAS_BACKGROUND=1: abre sem roubar o foco (capturas de tela e testes de interface).
        if ProcessInfo.processInfo.environment["LIBRAS_BACKGROUND"] != "1" {
            NSApp.activate()
        }
        MainActor.assumeIsolated { Self.model.bootstrap() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Salva caches e fecha o servidor, mas nunca segura o encerramento por mais de 2 s.
        let reply = { @MainActor [weak self] in
            guard let self, !self.terminationReplied else { return }
            self.terminationReplied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await Self.model.shutdown()
            reply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { reply() }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Atalhos ⌘1…⌘7 para as telas (botões fixos: listas dinâmicas no menu fazem o SwiftUI reconstruí-lo sem parar).
private struct SectionCommands: View {
    let navigation: NavigationModel

    var body: some View {
        Button(AppSection.live.title) { navigation.section = .live }.keyboardShortcut("1")
        Button(AppSection.audio.title) { navigation.section = .audio }.keyboardShortcut("2")
        Button(AppSection.avatar.title) { navigation.section = .avatar }.keyboardShortcut("3")
        Button(AppSection.obs.title) { navigation.section = .obs }.keyboardShortcut("4")
        Button(AppSection.translation.title) { navigation.section = .translation }.keyboardShortcut("5")
        Button(AppSection.ai.title) { navigation.section = .ai }.keyboardShortcut("6")
        Button(AppSection.logs.title) { navigation.section = .logs }.keyboardShortcut("7")
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isListening ? "Parar de ouvir" : "Começar a ouvir", systemImage: model.isListening ? "stop.fill" : "mic.fill") {
            model.toggleListening()
        }
        Button("Limpar fila", systemImage: "xmark.bin") { model.clearQueue() }
        Divider()
        let visible = model.overlayReady - model.overlayHidden
        Text(visible > 0 ? "OBS conectado" : "OBS aguardando")
        Text(String(format: "Atraso %.1f s · fila %d · %.1f×", model.snapshot.lag, model.snapshot.queued, model.snapshot.speed))
        Divider()
        Button("Copiar URL do overlay", systemImage: "link") { model.copyOverlayURL() }
        Button("Abrir o Libras Live", systemImage: "macwindow") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Sair") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
