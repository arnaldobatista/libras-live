import Foundation

/// Converte português em glosa de Libras.
public protocol GlossTranslating: Sendable {
    func gloss(for text: String) async throws -> String
}

public enum GlossError: Error, LocalizedError {
    case badStatus(Int)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case let .badStatus(code): "Tradutor respondeu HTTP \(code)"
        case .emptyResponse: "Tradutor devolveu glosa vazia"
        }
    }
}

/// Cliente da API pública do VLibras (`POST /translate {text}` → glosa em texto puro).
public struct VLibrasGlossClient: GlossTranslating {
    public static let defaultEndpoint = URL(string: "https://traducao2.vlibras.gov.br/translate")!

    public let endpoint: URL
    public let timeout: TimeInterval
    private let session: URLSession

    public init(endpoint: URL = defaultEndpoint, timeout: TimeInterval = 3, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.session = session
    }

    public func gloss(for text: String) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GlossError.badStatus(http.statusCode)
        }
        let gloss = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gloss.isEmpty else { throw GlossError.emptyResponse }
        return gloss
    }
}

public enum GlossSource: String, Sendable {
    case cache, remote, fallback
}

public struct GlossResult: Sendable, Equatable {
    public let gloss: String
    public let source: GlossSource
    public let duration: TimeInterval
    public let error: String?
}

/// Tradução com cache LRU em memória e persistência em disco.
public actor GlossService {
    private let translator: GlossTranslating
    private let capacity: Int
    private let cacheURL: URL?

    private var entries: [String: (gloss: String, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    private var dirty = 0

    /// Tentativas antes de desistir e usar a glosa de emergência.
    private let attempts: Int

    public init(translator: GlossTranslating = VLibrasGlossClient(), capacity: Int = 5000, cacheURL: URL? = nil, attempts: Int = 2) {
        self.translator = translator
        self.attempts = max(1, attempts)
        self.capacity = max(10, capacity)
        self.cacheURL = cacheURL
    }

    public var count: Int { entries.count }

    public func translate(_ text: String) async -> GlossResult {
        let started = Date()
        let key = Self.key(for: text)

        if let hit = entries[key] {
            touch(key, gloss: hit.gloss)
            return GlossResult(gloss: hit.gloss, source: .cache, duration: Date().timeIntervalSince(started), error: nil)
        }

        var lastError: Error?
        for _ in 0..<attempts {
            do {
                let gloss = try await translator.gloss(for: text)
                touch(key, gloss: gloss)
                dirty += 1
                if dirty >= 25 { save() }
                return GlossResult(gloss: gloss, source: .remote, duration: Date().timeIntervalSince(started), error: nil)
            } catch {
                lastError = error
            }
        }
        return GlossResult(
            gloss: Self.fallbackGloss(for: text),
            source: .fallback,
            duration: Date().timeIntervalSince(started),
            error: lastError?.localizedDescription
        )
    }

    /// Sem tradução: palavras em maiúsculas, sem pontuação. O player soletra o que não conhece.
    public static func fallbackGloss(for text: String) -> String {
        text.uppercased()
            .unicodeScalars
            .map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func key(for text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func touch(_ key: String, gloss: String) {
        tick += 1
        entries[key] = (gloss, tick)
        if entries.count > capacity { evict() }
    }

    private func evict() {
        let removeCount = max(1, capacity / 10)
        let oldest = entries.sorted { $0.value.tick < $1.value.tick }.prefix(removeCount)
        for (key, _) in oldest { entries.removeValue(forKey: key) }
    }

    // MARK: Disco

    public func load() {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (key, gloss) in stored {
            tick += 1
            entries[key] = (gloss, tick)
        }
    }

    public func save() {
        guard let cacheURL else { return }
        dirty = 0
        let snapshot = entries.mapValues(\.gloss)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
        } catch {
            // Cache é otimização; falha ao salvar não interrompe a live.
        }
    }
}
