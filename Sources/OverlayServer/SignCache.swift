import Foundation

/// Cache em disco das animações de sinais do VLibras.
///
/// O player Unity pede `<baseUrl>/<SINAL>`. O servidor do VLibras responde com
/// redirecionamento para o arquivo do sinal ou 404 quando o sinal não existe
/// (nesse caso o avatar soletra). Guardamos os arquivos em disco e os 404 em
/// memória, e deduplicamos downloads simultâneos do mesmo sinal.
public actor SignCache {
    public static let defaultUpstream = URL(string: "https://dicionario2.vlibras.gov.br/2018.3.1/WEBGL/")!

    public enum FetchResult: Sendable {
        case hit(Data)
        case downloaded(Data)
        case notFound
        case failed(String)
    }

    public struct Stats: Sendable, Equatable, Codable {
        public var hits = 0
        public var downloads = 0
        public var notFound = 0
        public var failures = 0
        public var bytesDownloaded = 0

        public init() {}
    }

    public let upstream: URL
    public let directory: URL
    public private(set) var stats = Stats()

    private let session: URLSession
    private var inFlight: [String: Task<FetchResult, Never>] = [:]
    private var misses: [String: Date] = [:]
    private let missTTL: TimeInterval = 6 * 60 * 60

    public init(directory: URL, upstream: URL = SignCache.defaultUpstream) {
        self.directory = directory
        self.upstream = upstream
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Nomes de sinal aceitos: letras (inclusive acentuadas), dígitos e símbolos usados em glosas
    /// (`PESSOAL&PARTICULAR`, `BOA_NOITE`, `[PONTO]`).
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 120, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "_-&.+[] ".unicodeScalars.contains(scalar)
        } && !name.contains("..")
    }

    public func fetch(_ name: String) async -> FetchResult {
        guard Self.isValidName(name) else { return .notFound }

        let file = fileURL(for: name)
        if let data = try? Data(contentsOf: file) {
            stats.hits += 1
            return .hit(data)
        }

        if let missed = misses[name], Date().timeIntervalSince(missed) < missTTL {
            stats.notFound += 1
            return .notFound
        }

        if let running = inFlight[name] {
            return await running.value
        }

        let task = Task { await self.download(name, to: file) }
        inFlight[name] = task
        let result = await task.value
        inFlight[name] = nil
        return result
    }

    /// Quais sinais existem no dicionário (baixa os que faltam, em paralelo).
    /// Falhas de rede ficam fora do resultado (disponibilidade desconhecida).
    public func availability(for names: [String]) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool?).self) { group in
            for name in Set(names) {
                group.addTask {
                    switch await self.fetch(name) {
                    case .hit, .downloaded: (name, true)
                    case .notFound: (name, SignCache.isValidName(name) ? false : nil)
                    case .failed: (name, nil)
                    }
                }
            }
            var result: [String: Bool] = [:]
            for await (name, exists) in group {
                if let exists { result[name] = exists }
            }
            return result
        }
    }

    /// Baixa em paralelo sinais que ainda não estão no cache.
    public func prefetch(_ names: [String]) async {
        let pending = Set(names).filter { name in
            Self.isValidName(name) && !FileManager.default.fileExists(atPath: fileURL(for: name).path)
        }
        await withTaskGroup(of: Void.self) { group in
            for name in pending {
                group.addTask { _ = await self.fetch(name) }
            }
        }
    }

    public func cachedCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        misses.removeAll()
        stats = Stats()
    }

    // MARK: Privado

    private func download(_ name: String, to file: URL) async -> FetchResult {
        let url = upstream.appendingPathComponent(name)
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                try? data.write(to: file, options: .atomic)
                stats.downloads += 1
                stats.bytesDownloaded += data.count
                return .downloaded(data)
            case 404:
                misses[name] = Date()
                stats.notFound += 1
                return .notFound
            default:
                stats.failures += 1
                return .failed("HTTP \(status)")
            }
        } catch {
            stats.failures += 1
            return .failed(error.localizedDescription)
        }
    }

    private func fileURL(for name: String) -> URL {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return directory.appendingPathComponent(safe, isDirectory: false)
    }
}
