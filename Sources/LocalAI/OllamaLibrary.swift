import Foundation

/// Busca na biblioteca pública do Ollama (ollama.com). Não há API oficial de busca:
/// lemos a página de resultados e a lista de versões de cada modelo.
public enum OllamaLibrary {
    public struct Model: Identifiable, Sendable, Equatable {
        public let name: String
        public let summary: String
        /// Tamanhos anunciados (ex.: "4b", "e2b").
        public let sizes: [String]
        public let capabilities: [String]
        /// Só roda na nuvem do Ollama (não baixa para o Mac).
        public let cloudOnly: Bool
        public let pulls: String
        public let updated: String

        public var id: String { name }
    }

    public struct Tag: Identifiable, Sendable, Equatable {
        /// Nome completo para baixar (ex.: "qwen3.5:4b").
        public let name: String
        public let size: String
        public let bytes: Int64?
        public let context: String
        public let inputs: String

        public var id: String { name }

        /// Versões que o motor embutido não roda no Mac: MLX (motor não incluído), NVFP4 (placas NVIDIA) e nuvem.
        public var runsHere: Bool {
            let lower = name.lowercased()
            return !lower.hasSuffix("-mlx") && !lower.contains("nvfp4") && !lower.contains("cloud")
        }
    }

    public static func search(_ query: String, session: URLSession = .shared) async throws -> [Model] {
        var components = URLComponents(string: "https://ollama.com/search")!
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { components.queryItems = [URLQueryItem(name: "q", value: trimmed)] }
        return parseSearch(try await fetch(components.url!, session: session))
    }

    public static func tags(for model: String, session: URLSession = .shared) async throws -> [Tag] {
        let base = model.split(separator: ":").first.map(String.init) ?? model
        guard let escaped = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ollama.com/library/\(escaped)/tags") else { return [] }
        return parseTags(try await fetch(url, session: session))
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "ollama.com indisponível")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Leitura das páginas

    public static func parseSearch(_ html: String) -> [Model] {
        blocks(in: html, open: "<li", close: "</li>").compactMap { block -> Model? in
            guard let name = firstMatch(#"href="/library/([^"]+)""#, in: block) else { return nil }
            let summary = firstMatch(#"<p class="max-w-lg[^"]*">(.*?)</p>"#, in: block).map(clean) ?? ""
            let capabilities = allMatches(#"bg-indigo-50[^"]*"[^>]*>([^<]+)</span>"#, in: block).map(clean)
            let sizes = allMatches(#"bg-\[#ddf4ff\][^"]*"[^>]*>([^<]+)</span>"#, in: block).map(clean)
            let cloud = block.contains("bg-cyan-50")
            let pulls = firstMatch(#"<span[^>]*>([^<]+)</span>\s*<span[^>]*>&nbsp;Pulls"#, in: block).map(clean) ?? ""
            let updated = firstMatch(#"Updated&nbsp;</span>\s*<span[^>]*>([^<]+)</span>"#, in: block).map(clean) ?? ""
            return Model(name: name, summary: summary, sizes: sizes, capabilities: capabilities, cloudOnly: cloud && sizes.isEmpty, pulls: pulls, updated: updated)
        }
    }

    public static func parseTags(_ html: String) -> [Tag] {
        var tags: [Tag] = []
        var seen = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"href="/library/([^"]+:[^"]+)" class="md:hidden"#)
        let range = NSRange(html.startIndex..., in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: html) else { continue }
            let name = String(html[nameRange])
            guard seen.insert(name).inserted else { continue }
            let tail = html[nameRange.upperBound...].prefix(1500)
            let segment = String(tail)
            let size = firstMatch(#"•\s*([\d.]+\s*[KMGT]?B)\s*•"#, in: segment) ?? "?"
            let context = firstMatch(#"•\s*([\d.]+[KM]?) context window"#, in: segment) ?? ""
            let inputs = firstMatch(#"<span class="hidden sm:inline">\s*([^•<]+?) input"#, in: segment).map(clean) ?? ""
            tags.append(Tag(name: name, size: size.replacingOccurrences(of: " ", with: ""), bytes: bytes(fromSize: size), context: context, inputs: inputs))
        }
        return tags
    }

    static func bytes(fromSize text: String) -> Int64? {
        let compact = text.replacingOccurrences(of: " ", with: "").uppercased()
        guard let unitIndex = compact.firstIndex(where: { $0.isLetter }), let value = Double(compact[..<unitIndex]) else { return nil }
        let unit = compact[unitIndex...]
        let multiplier: Double = switch unit {
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 1
        }
        return Int64(value * multiplier)
    }

    // MARK: Utilidades

    private static func blocks(in html: String, open: String, close: String) -> [String] {
        var result: [String] = []
        var searchStart = html.startIndex
        while let start = html.range(of: open, range: searchStart..<html.endIndex),
              let end = html.range(of: close, range: start.upperBound..<html.endIndex) {
            result.append(String(html[start.lowerBound..<end.upperBound]))
            searchStart = end.upperBound
        }
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func clean(_ text: String) -> String {
        var value = text
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&rsquo;": "’", "&ldquo;": "“", "&rdquo;": "”"]
        for (entity, character) in entities {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        return value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
