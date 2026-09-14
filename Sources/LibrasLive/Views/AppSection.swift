import Observation
import SwiftUI

/// Estado de interface compartilhado entre as cenas: tela selecionada e ícone na barra de menus.
@MainActor
@Observable
final class NavigationModel {
    private static let sectionKey = "LibrasLive.section"
    private static let menuBarKey = "LibrasLive.showMenuBarExtra"

    var section: AppSection? {
        didSet {
            if let section, section != oldValue { UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey) }
        }
    }

    /// Só grava quando o valor muda: o MenuBarExtra reescreve o binding a cada atualização da cena,
    /// e uma gravação repetida (ex.: via @AppStorage) invalida a cena de novo, num laço sem fim.
    var showMenuBarExtra: Bool {
        didSet {
            if showMenuBarExtra != oldValue { UserDefaults.standard.set(showMenuBarExtra, forKey: Self.menuBarKey) }
        }
    }

    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let stored = environment["LIBRAS_SECTION"] ?? defaults.string(forKey: Self.sectionKey)
        section = stored.flatMap(AppSection.init(rawValue:)) ?? .live
        showMenuBarExtra = defaults.object(forKey: Self.menuBarKey) as? Bool ?? true
    }

    var menuBarBinding: Binding<Bool> {
        Binding(
            get: { self.showMenuBarExtra },
            set: { newValue in
                if newValue != self.showMenuBarExtra { self.showMenuBarExtra = newValue }
            }
        )
    }
}

/// Telas da barra lateral.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case live, audio, avatar, obs, translation, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Ao vivo"
        case .audio: "Áudio"
        case .avatar: "Avatar"
        case .obs: "OBS"
        case .translation: "Tradução"
        case .logs: "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .audio: "waveform"
        case .avatar: "person.crop.square"
        case .obs: "rectangle.on.rectangle"
        case .translation: "character.bubble"
        case .logs: "doc.text.magnifyingglass"
        }
    }

    static let broadcast: [AppSection] = [.live, .audio, .avatar, .obs]
    static let tuning: [AppSection] = [.translation, .logs]
}
