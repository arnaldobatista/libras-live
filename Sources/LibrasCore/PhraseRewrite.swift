import Foundation

/// Quanto a IA pode mexer no que foi dito antes da tradução para Libras.
public enum RewriteMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Corrige transcrição, pontuação e concordância e completa lacunas óbvias; mantém palavras e ordem.
    case faithful
    /// Corrige, completa e tira repetições e muletas; mantém o sentido e quase todas as palavras.
    case balanced
    /// Faz uma versão nova, com frases curtas e diretas.
    case rewrite

    public var id: String { rawValue }
}

// MARK: - Prompt

/// Pedido para o modelo local: instruções, trecho e limites de geração.
public struct RewritePrompt: Equatable, Sendable {
    public let system: String
    public let user: String
    public let temperature: Double
    public let maxTokens: Int

    public static func make(text: String, mode: RewriteMode, context: [String] = []) -> RewritePrompt {
        let words = PhraseText.words(in: text).count
        let system = [baseInstructions, instructions(for: mode)].joined(separator: "\n\n")

        var user = ""
        let previous = context.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !previous.isEmpty {
            user += "Contexto (frases anteriores, só para entender; não repita):\n\(previous.joined(separator: " "))\n\n"
        }
        user += "Trecho:\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"

        return RewritePrompt(
            system: system,
            user: user,
            temperature: temperature(for: mode),
            maxTokens: min(240, Int((Double(words) * 2.5).rounded(.up)) + 24)
        )
    }

    static let baseInstructions = """
    Você revisa trechos de fala transcritos automaticamente de uma transmissão ao vivo em português do Brasil. \
    O resultado vai ser traduzido para Libras por um avatar.
    Regras:
    - Responda só com o trecho revisado, em uma linha, sem aspas, títulos ou explicações.
    - Nunca invente fatos, nomes ou números que não estejam no trecho.
    - Se o trecho já estiver bom, repita-o igual.
    """

    static func instructions(for mode: RewriteMode) -> String {
        switch mode {
        case .faithful:
            """
            Modo fiel: corrija só erros claros de transcrição, pontuação, acentuação e concordância. \
            Mantenha as mesmas palavras, na mesma ordem. Complete apenas uma palavra ou ligação que esteja obviamente faltando.
            """
        case .balanced:
            """
            Modo intermediário: corrija erros, complete lacunas óbvias e tire repetições, hesitações e muletas \
            (como "né", "tipo", "aí", "então assim"). Mantenha o sentido e quase todas as palavras originais.
            """
        case .rewrite:
            """
            Modo nova versão: reescreva com frases curtas e diretas, em ordem simples (quem faz, o quê, com quem), \
            usando palavras comuns. Pode reorganizar e enxugar, mas mantenha todo o sentido.
            """
        }
    }

    static func temperature(for mode: RewriteMode) -> Double {
        switch mode {
        case .faithful: 0.1
        case .balanced: 0.2
        case .rewrite: 0.3
        }
    }
}

// MARK: - Validação

/// Confere a resposta do modelo antes de ela substituir o que foi falado.
public enum RewriteValidator {
    public enum Outcome: Equatable, Sendable {
        /// Texto aceito (`changed` diz se é diferente do original).
        case accepted(String, changed: Bool)
        case rejected(reason: String)
    }

    /// Limpa a resposta: raciocínio exposto, rótulos, aspas, markdown e quebras de linha.
    public static func clean(_ raw: String) -> String {
        var text = raw

        // Modelos com raciocínio podem devolver <think>…</think> mesmo com ele desligado.
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.replacingOccurrences(of: "</think>", with: "")

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        text = lines.joined(separator: " ")

        text = text.replacingOccurrences(of: "**", with: "")
        let labels = ["trecho revisado:", "trecho:", "texto revisado:", "texto:", "resposta:", "versão:", "nova versão:", "reescrita:", "correção:"]
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            for label in labels where lower.hasPrefix(label) {
                text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }

        let quotes: Set<Character> = ["\"", "“", "”", "'", "«", "»", "`"]
        while let first = text.first, quotes.contains(first) { text.removeFirst() }
        while let last = text.last, quotes.contains(last) { text.removeLast() }

        return text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func validate(original: String, output raw: String, mode: RewriteMode) -> Outcome {
        let text = clean(raw)
        guard !text.isEmpty else { return .rejected(reason: "resposta vazia") }

        let lower = text.lowercased()
        let chatter = ["aqui está", "claro,", "claro!", "certo,", "desculpe", "não entendi", "como assistente", "não há trecho", "não posso"]
        if chatter.contains(where: { lower.hasPrefix($0) }) {
            return .rejected(reason: "resposta fora do formato")
        }

        let originalWords = PhraseText.words(in: original)
        let outputWords = PhraseText.words(in: text)
        guard !originalWords.isEmpty else { return .rejected(reason: "trecho vazio") }

        let limits = Limits(mode: mode, words: originalWords.count)
        if outputWords.count > limits.maxWords {
            return .rejected(reason: "resposta longa demais")
        }
        if outputWords.count < limits.minWords {
            return .rejected(reason: "resposta curta demais")
        }
        if PhraseText.keptContent(original: originalWords, output: outputWords) < limits.minKept {
            return .rejected(reason: "mudou o sentido")
        }

        let changedText = PhraseText.normalized(original) != PhraseText.normalized(text)
        return .accepted(text, changed: changedText)
    }

    struct Limits {
        let maxWords: Int
        let minWords: Int
        /// Fração mínima das palavras de conteúdo do original que precisa continuar na resposta.
        let minKept: Double

        init(mode: RewriteMode, words: Int) {
            let count = Double(words)
            switch mode {
            case .faithful:
                maxWords = words + max(3, Int((count * 0.3).rounded(.up)))
                minWords = max(1, Int((count * 0.6).rounded(.down)))
                minKept = 0.7
            case .balanced:
                maxWords = words + max(4, Int((count * 0.4).rounded(.up)))
                minWords = max(1, Int((count * 0.4).rounded(.down)))
                minKept = 0.45
            case .rewrite:
                maxWords = Int((count * 1.6).rounded(.up)) + 6
                minWords = max(1, Int((count * 0.25).rounded(.down)))
                minKept = 0.25
            }
        }
    }
}

// MARK: - Agrupamento

/// Como os trechos confirmados viram o texto enviado à IA.
public struct RewriteGrouping: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Frase inteira: fecha no ponto final (frases com menos de `minimumSentenceWords` palavras juntam com a seguinte).
        case sentence
        /// Junta um número de palavras e espera um ponto final (ou vírgula) por mais algumas.
        case words
    }

    public var mode: Mode = .sentence
    /// Frase inteira: limite de palavras quando o ponto não vem. Por palavras: quantas juntar.
    public var words: Int = 30
    /// Por palavras: quantas a mais pode esperar para terminar num ponto final ou vírgula.
    public var extraWords: Int = 6
    /// Silêncio na fala (s) que fecha o trecho mesmo sem ponto.
    public var pauseSeconds: Double = 2

    public static let minimumSentenceWords = 6

    public init(mode: Mode = .sentence, words: Int = 30, extraWords: Int = 6, pauseSeconds: Double = 2) {
        self.mode = mode
        self.words = words
        self.extraWords = extraWords
        self.pauseSeconds = pauseSeconds
    }

    /// Frase inteira sem ponto: folga para ainda terminar numa vírgula depois do limite.
    public var sentenceSlack: Int { max(3, words / 5) }

    /// Maior trecho possível.
    public var limitWords: Int {
        mode == .words ? words + extraWords : words + sentenceSlack
    }

    public init(from decoder: Decoder) throws {
        let defaults = RewriteGrouping()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? defaults.mode
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? defaults.words
        extraWords = try c.decodeIfPresent(Int.self, forKey: .extraWords) ?? defaults.extraWords
        pauseSeconds = try c.decodeIfPresent(Double.self, forKey: .pauseSeconds) ?? defaults.pauseSeconds
    }
}

/// Junta trechos confirmados no texto que vai para a IA.
///
/// O reconhecedor confirma a fala em pedaços de poucas palavras (um a cada 3 ou 4 s na fala corrida);
/// reescrever cada pedaço sozinho não completa lacunas nem corrige a frase. O trecho fecha no ponto final
/// ou ao juntar as palavras escolhidas (com uma folga para terminar no ponto), quando a fala para
/// ou quando espera demais.
public struct RewriteBuffer: Sendable {
    public struct Unit: Equatable, Sendable {
        public let text: String
        /// Quando o primeiro pedaço chegou (para medir o atraso que a espera acrescenta).
        public let startedAt: Date
        public let sources: [String]

        public init(text: String, startedAt: Date, sources: [String]) {
            self.text = text
            self.startedAt = startedAt
            self.sources = sources
        }
    }

    public var grouping: RewriteGrouping

    private var text = ""
    private var startedAt: Date?
    private var lastAppendAt: Date?
    private var sources: [String] = []

    public init(grouping: RewriteGrouping = RewriteGrouping()) {
        self.grouping = grouping
    }

    public var pendingText: String { text }
    public var pendingWords: Int { PhraseText.words(in: text).count }
    public var isEmpty: Bool { text.isEmpty }

    /// Espera máxima de um trecho, mesmo com a fala seguindo sem ponto (0,8 s por palavra do limite;
    /// na fala corrida saem umas 2 palavras por segundo).
    var maxAge: TimeInterval { max(10, Double(grouping.limitWords) * 0.8) }

    /// Acrescenta um pedaço e devolve os trechos que ficaram completos.
    public mutating func append(_ piece: String, source: String, at now: Date) -> [Unit] {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if text.isEmpty { startedAt = now }
        text = PhraseText.join(text, trimmed)
        lastAppendAt = now
        if sources.last != source { sources.append(source) }

        var units: [Unit] = []
        while let unit = nextCompleteUnit(at: now) {
            units.append(unit)
        }
        return units
    }

    /// Fecha o trecho quando a fala parou ou quando ele já espera demais.
    /// - Parameter silence: segundos sem voz no áudio (nil sem detector: conta desde o último pedaço).
    public mutating func tick(at now: Date, silence: TimeInterval? = nil) -> Unit? {
        guard !text.isEmpty, let lastAppendAt, let startedAt else { return nil }
        let sinceAppend = now.timeIntervalSince(lastAppendAt)
        // O último pedaço da frase chega um pouco depois do silêncio: espera ao menos 1 s sem pedaço novo.
        let paused = (silence ?? sinceAppend) >= grouping.pauseSeconds && sinceAppend >= min(1, grouping.pauseSeconds)
        if paused || now.timeIntervalSince(startedAt) >= maxAge {
            return flush()
        }
        return nil
    }

    /// Fecha o que houver (fim da escuta, texto digitado).
    public mutating func flush() -> Unit? {
        guard !text.isEmpty else { return nil }
        let unit = Unit(text: text, startedAt: startedAt ?? Date(), sources: sources)
        reset()
        return unit
    }

    public mutating func reset() {
        text = ""
        startedAt = nil
        lastAppendAt = nil
        sources = []
    }

    private mutating func nextCompleteUnit(at now: Date) -> Unit? {
        let tokens = PhraseText.tokens(in: text)
        guard let total = tokens.last?.wordsUpTo, total > 0 else { return nil }

        switch grouping.mode {
        case .sentence:
            // Primeiro ponto final com palavras suficientes.
            if let end = tokens.first(where: { $0.endsSentence && $0.wordsUpTo >= RewriteGrouping.minimumSentenceWords }) {
                return cut(after: end, tokens: tokens, now: now)
            }
            let limit = grouping.limitWords
            if total >= limit {
                // Sem ponto: corta na última vírgula depois da metade (podendo passar um pouco do limite), senão no limite.
                let breakToken = tokens.last { $0.breaksClause && $0.wordsUpTo >= grouping.words / 2 && $0.wordsUpTo <= limit }
                return cut(after: breakToken ?? tokens.first { $0.wordsUpTo >= limit }!, tokens: tokens, now: now)
            }
        case .words:
            let target = grouping.words
            let limit = grouping.limitWords
            if let end = tokens.first(where: { $0.endsSentence && $0.wordsUpTo >= target && $0.wordsUpTo <= limit }) {
                return cut(after: end, tokens: tokens, now: now)
            }
            if total >= limit {
                let breakToken = tokens.last { ($0.breaksClause || $0.endsSentence) && $0.wordsUpTo >= target && $0.wordsUpTo <= limit }
                return cut(after: breakToken ?? tokens.first { $0.wordsUpTo >= limit }!, tokens: tokens, now: now)
            }
        }
        return nil
    }

    private mutating func cut(after token: PhraseText.Token, tokens: [PhraseText.Token], now: Date) -> Unit {
        let head = String(text[..<token.end]).trimmingCharacters(in: .whitespaces)
        let tail = String(text[token.end...]).trimmingCharacters(in: .whitespaces)
        let unit = Unit(text: head, startedAt: startedAt ?? now, sources: sources)
        if PhraseText.hasContent(tail) {
            text = tail
            startedAt = now
            sources = sources.last.map { [$0] } ?? []
        } else {
            reset()
        }
        return unit
    }
}

// MARK: - Texto

enum PhraseText {
    static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
    static let clauseBreaks: Set<Character> = [",", ";", ":"]

    /// Palavra do texto com a posição onde termina e quantas palavras há até ela.
    struct Token {
        let end: String.Index
        let wordsUpTo: Int
        let endsSentence: Bool
        let breaksClause: Bool
    }

    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            let piece = text[index..<end]
            if piece.contains(where: { $0.isLetter || $0.isNumber }) { count += 1 }
            let last = piece.last!
            tokens.append(Token(end: end, wordsUpTo: count, endsSentence: sentenceEnders.contains(last), breaksClause: clauseBreaks.contains(last)))
            index = end
        }
        return tokens
    }

    static func words(in text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    static func hasContent(_ text: String) -> Bool {
        text.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// Junta dois pedaços sem espaço antes de pontuação (", isso é" → "texto, isso é").
    static func join(_ current: String, _ piece: String) -> String {
        guard !current.isEmpty else { return piece }
        if let first = piece.first, [",", ".", ";", ":", "!", "?", "…"].contains(first) {
            return current + piece
        }
        return current + " " + piece
    }

    static func normalized(_ text: String) -> String {
        words(in: text)
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR")) }
            .joined(separator: " ")
    }

    /// Fração das palavras de conteúdo (4+ letras) do original que continuam na resposta.
    static func keptContent(original: [String], output: [String]) -> Double {
        func content(_ words: [String]) -> [String] {
            words
                .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR")) }
                .filter { $0.count >= 4 }
        }
        let source = content(original)
        guard !source.isEmpty else { return 1 }
        let target = content(output)
        let kept = source.filter { word in target.contains { sameRoot(word, $0) } }.count
        return Double(kept) / Double(source.count)
    }

    /// Mesma palavra ou flexão dela (falamos/falar, casas/casa, transformador/transformadores).
    static func sameRoot(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let needed = max(4, min(a.count, b.count) - 3)
        return a.commonPrefix(with: b).count >= needed
    }
}
