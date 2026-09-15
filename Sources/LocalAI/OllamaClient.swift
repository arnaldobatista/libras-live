import Foundation

/// Cliente da API HTTP do Ollama (servidor local).
public struct OllamaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public init(port: Int) {
        self.init(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
    }

    // MARK: Consultas

    public func version() async throws -> String {
        struct Response: Decodable { let version: String }
        let response: Response = try await get("api/version", timeout: 2)
        return response.version
    }

    public func installedModels() async throws -> [InstalledModel] {
        struct Response: Decodable { let models: [InstalledModel] }
        let response: Response = try await get("api/tags", timeout: 5)
        return response.models
    }

    public func runningModels() async throws -> [RunningModel] {
        struct Response: Decodable { let models: [RunningModel] }
        let response: Response = try await get("api/ps", timeout: 5)
        return response.models
    }

    public func show(_ model: String) async throws -> ModelInfo {
        try await send("api/show", method: "POST", body: ["model": model], timeout: 10)
    }

    // MARK: Modelos

    /// Baixa um modelo, com o progresso de cada camada. Cancelar a tarefa interrompe o download
    /// (o que já veio fica guardado e o próximo download continua de onde parou).
    public func pull(_ model: String) -> AsyncThrowingStream<PullEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest("api/pull", method: "POST", body: ["model": model, "stream": true])
                    request.timeoutInterval = 60 * 60 * 6
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.check(response, body: nil)
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                        let event = try Self.decoder.decode(PullEvent.self, from: data)
                        if let error = event.error { throw OllamaError.server(error) }
                        continuation.yield(event)
                        if event.status == "success" { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func delete(_ model: String) async throws {
        let request = try makeRequest("api/delete", method: "DELETE", body: ["model": model])
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
    }

    /// Contexto usado em todas as chamadas: com outro valor o Ollama recarrega o modelo (2 a 7 s).
    public static let contextLength = 2048

    /// Carrega o modelo na memória e deixa pronto por `keepAlive` (ex.: "30m"; "-1" = até fechar).
    public func load(_ model: String, keepAlive: String) async throws {
        struct Response: Decodable {}
        let body: [String: Any] = ["model": model, "keep_alive": keepAlive, "options": ["num_ctx": Self.contextLength]]
        let _: Response = try await send("api/generate", method: "POST", body: body, timeout: 120)
    }

    /// Tira o modelo da memória.
    public func unload(_ model: String) async throws {
        struct Response: Decodable {}
        let _: Response = try await send("api/generate", method: "POST", body: ["model": model, "keep_alive": 0], timeout: 20)
    }

    // MARK: Conversa

    public struct ChatMessage: Codable, Sendable, Equatable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct ChatOptions: Encodable, Sendable {
        public var temperature: Double
        public var numPredict: Int
        public var numCtx: Int

        public init(temperature: Double, numPredict: Int, numCtx: Int = OllamaClient.contextLength) {
            self.temperature = temperature
            self.numPredict = numPredict
            self.numCtx = numCtx
        }
    }

    public struct ChatResult: Sendable, Equatable {
        public let content: String
        /// Tempo total no servidor, incluindo carregar o modelo.
        public let totalDuration: TimeInterval
        public let loadDuration: TimeInterval
        public let generatedTokens: Int
    }

    /// Uma resposta completa (sem streaming). `think: false` desliga o raciocínio dos modelos que pensam.
    public func chat(model: String, messages: [ChatMessage], options: ChatOptions, think: Bool?, keepAlive: String?, timeout: TimeInterval) async throws -> ChatResult {
        struct Request: Encodable {
            let model: String
            let messages: [ChatMessage]
            let stream = false
            let think: Bool?
            let keepAlive: String?
            let options: ChatOptions
        }
        struct Response: Decodable {
            let message: ChatMessage
            let totalDuration: Int64?
            let loadDuration: Int64?
            let evalCount: Int?
        }

        var request = try makeRequest("api/chat", method: "POST", encodable: Request(model: model, messages: messages, think: think, keepAlive: keepAlive, options: options))
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        let decoded = try Self.decoder.decode(Response.self, from: data)
        return ChatResult(
            content: decoded.message.content,
            totalDuration: Double(decoded.totalDuration ?? 0) / 1e9,
            loadDuration: Double(decoded.loadDuration ?? 0) / 1e9,
            generatedTokens: decoded.evalCount ?? 0
        )
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ path: String, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func send<T: Decodable>(_ path: String, method: String, body: [String: Any], timeout: TimeInterval) async throws -> T {
        var request = try makeRequest(path, method: method, body: body)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func makeRequest(_ path: String, method: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeRequest(_ path: String, method: String, encodable: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(encodable)
        return request
    }

    private static func check(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw OllamaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
            throw OllamaError.http(http.statusCode, message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = OllamaDate.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Data inválida: \(text)"))
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}

public enum OllamaError: LocalizedError, Equatable {
    case http(Int, String)
    case server(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .http(code, message): "O motor de IA respondeu \(code): \(message)"
        case let .server(message): "O motor de IA avisou: \(message)"
        case .invalidResponse: "Resposta inválida do motor de IA."
        }
    }
}

// MARK: - Tipos da API

public struct InstalledModel: Identifiable, Sendable, Equatable, Decodable {
    public struct Details: Sendable, Equatable, Decodable {
        public let family: String?
        public let parameterSize: String?
        public let quantizationLevel: String?
    }

    public let name: String
    public let size: Int64
    public let digest: String?
    public let modifiedAt: Date?
    public let details: Details?
    public let capabilities: [String]?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, size, digest, modifiedAt, details, capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
        modifiedAt = try? container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        details = try? container.decodeIfPresent(Details.self, forKey: .details)
        capabilities = try? container.decodeIfPresent([String].self, forKey: .capabilities)
    }

    public init(name: String, size: Int64, parameterSize: String? = nil, quantization: String? = nil) {
        self.name = name
        self.size = size
        digest = nil
        modifiedAt = nil
        details = Details(family: nil, parameterSize: parameterSize, quantizationLevel: quantization)
        capabilities = nil
    }
}

public struct RunningModel: Identifiable, Sendable, Equatable, Decodable {
    public let name: String
    public let size: Int64
    public let sizeVram: Int64?
    public let expiresAt: Date?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, size, sizeVram, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sizeVram = try container.decodeIfPresent(Int64.self, forKey: .sizeVram)
        expiresAt = try? container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}

public struct ModelInfo: Sendable, Equatable, Decodable {
    public let capabilities: [String]?

    public var thinks: Bool { capabilities?.contains("thinking") == true }
}

public struct PullEvent: Sendable, Equatable, Decodable {
    public let status: String?
    public let digest: String?
    public let total: Int64?
    public let completed: Int64?
    public let error: String?
}

enum OllamaDate {
    /// "2026-09-15T09:49:53.436950674-03:00": o Ollama manda nanossegundos, que o ISO8601DateFormatter não lê.
    static func parse(_ text: String) -> Date? {
        var trimmed = text
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<zone].prefix(3)
            trimmed = String(text[..<dot]) + "." + fraction.padding(toLength: 3, withPad: "0", startingAt: 0) + String(text[zone...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
