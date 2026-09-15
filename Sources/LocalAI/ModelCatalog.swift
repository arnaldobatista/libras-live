import Foundation

/// O Mac em que o app roda: memória e processador decidem que modelo cabe.
public struct MachineInfo: Sendable, Equatable {
    public let modelName: String
    public let chip: String
    public let memoryGB: Int

    public init(modelName: String, chip: String, memoryGB: Int) {
        self.modelName = modelName
        self.chip = chip
        self.memoryGB = memoryGB
    }

    public static func current() -> MachineInfo {
        let memory = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return MachineInfo(
            modelName: friendlyName(forIdentifier: sysctlString("hw.model") ?? ""),
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            memoryGB: memory
        )
    }

    public var summary: String { "\(modelName) · \(chip) · \(memoryGB) GB" }

    static func friendlyName(forIdentifier identifier: String) -> String {
        let names = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("Macmini", "Mac mini"), ("MacStudio", "Mac Studio"), ("MacPro", "Mac Pro"), ("iMac", "iMac")]
        return names.first { identifier.hasPrefix($0.0) }?.1 ?? "Mac"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Modelos testados para reescrever fala em português ao vivo, com as medidas num MacBook Pro M1 Pro 16 GB
/// (frases reais de transmissões, contexto de 2048 tokens; com o avatar sinalizando junto, cerca de 50% mais lento).
public enum ModelCatalog {
    public struct Recommendation: Identifiable, Sendable, Equatable {
        public enum Badge: String, Sendable {
            case recommended = "Recomendado"
            case fastest = "Mais rápido"
            case careful = "Mais caprichado"
        }

        public let name: String
        public let title: String
        public let badge: Badge
        public let downloadGB: Double
        /// Memória usada com o modelo carregado.
        public let memoryGB: Double
        /// Tempo típico por frase medido no M1 Pro.
        public let secondsPerPhrase: Double
        public let summary: String

        public var id: String { name }
    }

    public enum Fit: Sendable, Equatable {
        case great, tight, tooBig
    }

    public static let recommendations: [Recommendation] = [
        Recommendation(
            name: "qwen3:4b-instruct-2507-q4_K_M",
            title: "Qwen3 4B Instruct",
            badge: .recommended,
            downloadGB: 2.5,
            memoryGB: 2.9,
            secondsPerPhrase: 1.0,
            summary: "Melhor equilíbrio para ao vivo: português natural, corrige a transcrição sem inventar e responde em cerca de 1 s."
        ),
        Recommendation(
            name: "gemma4:e2b-it-qat",
            title: "Gemma 4 E2B",
            badge: .fastest,
            downloadGB: 4.3,
            memoryGB: 3.6,
            secondsPerPhrase: 0.8,
            summary: "O mais rápido dos bons. Na nova versão faz frases curtas e diretas, que viram Libras com facilidade; no modo fiel às vezes corta palavras."
        ),
        Recommendation(
            name: "qwen3.5:4b",
            title: "Qwen 3.5 4B",
            badge: .careful,
            downloadGB: 3.4,
            memoryGB: 3.1,
            secondsPerPhrase: 1.6,
            summary: "Corrige mais erros do reconhecedor (\"chatspots\" → \"chatbots\"), mas é mais lento. Use com tempo máximo de 3 s."
        ),
    ]

    public static var defaultModel: String { recommendations[0].name }

    /// Quanto o modelo pesa neste Mac, deixando espaço para o sistema, o OBS e o reconhecimento de fala.
    public static func fit(memoryGB modelMemory: Double, on machine: MachineInfo) -> Fit {
        let spare = Double(machine.memoryGB) - 8
        if modelMemory <= spare * 0.6 { return .great }
        if modelMemory <= spare { return .tight }
        return .tooBig
    }

    /// Mesmo modelo, considerando a tag padrão ("llama3.2" = "llama3.2:latest").
    public static func sameModel(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    static func normalized(_ name: String) -> String {
        name.contains(":") ? name.lowercased() : name.lowercased() + ":latest"
    }
}
