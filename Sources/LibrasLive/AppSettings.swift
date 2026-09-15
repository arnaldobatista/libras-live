import Foundation
import LibrasCore

enum Avatar: String, CaseIterable, Codable, Identifiable {
    case icaro, hosana, guga

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icaro: "Ícaro"
        case .hosana: "Hosana"
        case .guga: "Guga"
        }
    }
}

/// Reescrita das frases com o modelo local antes da tradução.
struct RewriteSettings: Codable, Equatable {
    var enabled = false
    var mode: RewriteMode = .faithful
    /// Nome do modelo no Ollama (ex.: "qwen3:4b-instruct-2507-q4_K_M").
    var model: String?
    /// Prazo por trecho (s); passou, vai o texto original.
    var timeout: Double = 3
    /// Manda as frases anteriores junto, para a IA entender o assunto.
    var useContext = true
    /// Quanto da fala vai de uma vez para a IA.
    var grouping = RewriteGrouping()

    init() {}

    /// Prazo para um trecho: o tempo máximo vale até 20 palavras; trechos maiores ganham proporcionalmente (até o dobro).
    func deadline(forWords words: Int) -> TimeInterval {
        timeout * min(2, max(1, Double(words) / 20))
    }

    init(from decoder: Decoder) throws {
        let defaults = RewriteSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        mode = (try? c.decodeIfPresent(RewriteMode.self, forKey: .mode)) ?? defaults.mode
        model = try c.decodeIfPresent(String.self, forKey: .model)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? defaults.timeout
        useContext = try c.decodeIfPresent(Bool.self, forKey: .useContext) ?? defaults.useContext
        grouping = (try? c.decodeIfPresent(RewriteGrouping.self, forKey: .grouping)) ?? defaults.grouping
    }
}

/// Preferências persistidas em UserDefaults.
struct AppSettings: Codable, Equatable {
    var deviceUID: String?
    /// Canais 0-based do dispositivo, somados em mono.
    var channels: [Int] = [0]
    var gainDB: Double = 0

    var port: Int = 8765
    var avatar: Avatar = .icaro
    var subtitles: Bool = false
    var useSignCache: Bool = true
    var prefetchSigns: Bool = true

    var policy = BacklogPolicy()
    var maxWords: Int = 14

    /// Palavras sem sinal no dicionário: soletrar, só curtas ou pular.
    var unknownWords: GlossOptimizer.UnknownWordPolicy = .spellShort
    /// Remove pausas de pontuação ([PONTO]) da glosa.
    var removePauses: Bool = true
    /// Silêncio no áudio (s) para confirmar o trecho pendente; a hipótese também precisa estar parada (0 desliga).
    var pauseCommitSeconds: Double = 0.6
    /// Confirma orações longas na vírgula.
    var commitOnComma: Bool = true
    /// Grava o log da sessão em disco.
    var logEnabled: Bool = true
    /// Cores e logo do avatar.
    var appearance = AvatarAppearance()
    /// Reescrita com IA local.
    var rewrite = RewriteSettings()

    var glossOptions: GlossOptimizer.Options {
        GlossOptimizer.Options(removePunctuationPauses: removePauses, unknownWords: unknownWords)
    }

    /// Resumo curto para o log.
    var logSummary: String {
        String(
            format: "vel %.1f–%.1f× · acelera %.0fs · descarta %.0fs · juntar %@ (%.0fs) · compactar %@ · repetidas %@ · sem sinal %@ · pausas %@ · silêncio p/ confirmar %.1fs",
            policy.baseSpeed, policy.maxSpeed, policy.speedUpAfter, policy.dropAfter,
            policy.mergePhrases ? "sim" : "não", policy.maxBatchSeconds,
            policy.compactWhenBehind ? "sim" : "não", policy.dropRepeats ? "sim" : "não",
            unknownWords.rawValue, removePauses ? "remove" : "mantém", pauseCommitSeconds
        ) + (rewrite.enabled ? String(
            format: " · IA %@ (%@, %.1fs, %@ %d%@, pausa %.1fs)",
            rewrite.mode.rawValue, rewrite.model ?? "sem modelo", rewrite.timeout,
            rewrite.grouping.mode == .sentence ? "até o ponto, máx." : "palavras", rewrite.grouping.words,
            rewrite.grouping.mode == .words ? "+\(rewrite.grouping.extraWords)" : "", rewrite.grouping.pauseSeconds
        ) : "")
    }

    var gainLinear: Float { Float(pow(10, gainDB / 20)) }

    private static let key = "LibrasLive.settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    /// Já existem preferências salvas (o app já foi usado antes desta versão).
    static func hasStoredSettings(in defaults: UserDefaults = .standard) -> Bool {
        defaults.data(forKey: key) != nil
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    // Decodificação tolerante: campos novos não quebram preferências antigas.
    init() {}

    init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        channels = try c.decodeIfPresent([Int].self, forKey: .channels) ?? defaults.channels
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? defaults.gainDB
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        avatar = (try? c.decodeIfPresent(Avatar.self, forKey: .avatar)) ?? defaults.avatar
        subtitles = try c.decodeIfPresent(Bool.self, forKey: .subtitles) ?? defaults.subtitles
        useSignCache = try c.decodeIfPresent(Bool.self, forKey: .useSignCache) ?? defaults.useSignCache
        prefetchSigns = try c.decodeIfPresent(Bool.self, forKey: .prefetchSigns) ?? defaults.prefetchSigns
        policy = (try? c.decodeIfPresent(BacklogPolicy.self, forKey: .policy)) ?? defaults.policy
        maxWords = try c.decodeIfPresent(Int.self, forKey: .maxWords) ?? defaults.maxWords
        unknownWords = (try? c.decodeIfPresent(GlossOptimizer.UnknownWordPolicy.self, forKey: .unknownWords)) ?? defaults.unknownWords
        removePauses = try c.decodeIfPresent(Bool.self, forKey: .removePauses) ?? defaults.removePauses
        pauseCommitSeconds = try c.decodeIfPresent(Double.self, forKey: .pauseCommitSeconds) ?? defaults.pauseCommitSeconds
        commitOnComma = try c.decodeIfPresent(Bool.self, forKey: .commitOnComma) ?? defaults.commitOnComma
        logEnabled = try c.decodeIfPresent(Bool.self, forKey: .logEnabled) ?? defaults.logEnabled
        appearance = (try? c.decodeIfPresent(AvatarAppearance.self, forKey: .appearance)) ?? defaults.appearance
        rewrite = (try? c.decodeIfPresent(RewriteSettings.self, forKey: .rewrite)) ?? defaults.rewrite
    }
}

enum AppPaths {
    /// Dados do app. `LIBRAS_SUPPORT_DIR` isola caches e logs (testes, segunda instância).
    static var support: URL {
        if let override = ProcessInfo.processInfo.environment["LIBRAS_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LibrasLive", isDirectory: true)
    }

    /// `LIBRAS_PORT` sobrepõe a porta salva sem alterá-la (testes, segunda instância).
    static var portOverride: Int? {
        ProcessInfo.processInfo.environment["LIBRAS_PORT"].flatMap(Int.init)
    }

    static var glossCache: URL { support.appendingPathComponent("gloss-cache.json") }
    /// Logo original enviada, `logo.png` (500 × 500 pronta para o player) e `blank.png`.
    static var appearance: URL { support.appendingPathComponent("appearance", isDirectory: true) }
    static var signCache: URL { support.appendingPathComponent("signs", isDirectory: true) }

    /// Motor de IA: modelos, chave e log. `LIBRAS_OLLAMA_DIR` aponta para outra pasta (ex.: reaproveitar modelos em testes).
    static var ollama: URL {
        if let override = ProcessInfo.processInfo.environment["LIBRAS_OLLAMA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return support.appendingPathComponent("ollama", isDirectory: true)
    }

    /// Executável do Ollama: variável de ambiente → dentro do .app → Vendor/ do projeto (desenvolvimento).
    static func ollamaBinary() -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["LIBRAS_OLLAMA_BIN"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("ollama/ollama"))
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            dir.deleteLastPathComponent()
            candidates.append(dir.appendingPathComponent("Vendor/ollama/ollama"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) } ?? candidates.first!
    }

    /// Pasta do overlay: variável de ambiente → dentro do .app → pasta do projeto (desenvolvimento).
    static func overlayDirectory() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let env = ProcessInfo.processInfo.environment["LIBRAS_OVERLAY_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Overlay"))
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            dir.deleteLastPathComponent()
            candidates.append(dir.appendingPathComponent("Overlay"))
        }

        return candidates.first { url in
            fm.fileExists(atPath: url.appendingPathComponent("index.html").path)
                && fm.fileExists(atPath: url.appendingPathComponent("vlibras/unity-loader.js").path)
        }
    }
}
