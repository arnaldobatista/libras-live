import Foundation

/// Ajusta a glosa do VLibras para o avatar sinalizar mais rápido sem perder conteúdo.
///
/// Problemas vistos em live real:
/// - `[PONTO]` no fim de cada frase custa uma pausa;
/// - repetições (`SENHOR SENHOR`);
/// - compostos sem sinal no dicionário (`NÃO_PRATICAR`) e palavras mal lematizadas
///   (`DISCERNIRMO`, `QUANTA`) viram datilologia letra a letra, que é lenta;
/// - quando a API falha, a frase inteira chega em português e é soletrada.
///
/// A disponibilidade de cada sinal vem do cache de sinais (`true` existe, `false` não existe,
/// ausente = desconhecido; desconhecido é tratado como existente).
public enum GlossOptimizer {
    public enum UnknownWordPolicy: String, Codable, Sendable, CaseIterable {
        /// Mantém: o avatar soletra.
        case spell
        /// Soletra só palavras curtas (nomes próprios costumam ser curtos).
        case spellShort
        /// Remove palavras sem sinal.
        case skip
    }

    public struct Options: Sendable, Equatable {
        public var removePunctuationPauses = true
        public var unknownWords: UnknownWordPolicy = .spellShort
        public var maxSpelledLetters = 6
        /// Remove muletas da fala (ENTÃO, AÍ, NÉ...). Usado quando há atraso.
        public var removeFillers = false

        public init(
            removePunctuationPauses: Bool = true,
            unknownWords: UnknownWordPolicy = .spellShort,
            maxSpelledLetters: Int = 6,
            removeFillers: Bool = false
        ) {
            self.removePunctuationPauses = removePunctuationPauses
            self.unknownWords = unknownWords
            self.maxSpelledLetters = maxSpelledLetters
            self.removeFillers = removeFillers
        }
    }

    public struct Result: Sendable, Equatable {
        public var tokens: [String]
        /// Tokens retirados (pausas, repetições, muletas, palavras sem sinal).
        public var removed: [String]
        /// Trocas feitas, no formato `ORIGINAL→NOVO`.
        public var replaced: [String]
        /// Tokens mantidos que o avatar vai soletrar.
        public var spelled: [String]

        public var gloss: String { tokens.joined(separator: " ") }
    }

    /// Marcações de pontuação que o VLibras insere. `[PONTO]` é só pausa; interrogação e
    /// exclamação carregam expressão facial e ficam.
    public static let pauseMarkers: Set<String> = ["[PONTO]", "[VÍRGULA]", "[PONTO_E_VÍRGULA]", "[DOIS_PONTOS]", "[RETICÊNCIAS]"]
    public static let fillers: Set<String> = ["ENTÃO", "AÍ", "NÉ", "TIPO", "ASSIM", "BOM", "OLHA"]

    /// Nomes alternativos a consultar no dicionário para um token sem sinal.
    /// Cada alternativa é uma sequência de sinais que substitui o token.
    public static func alternatives(for token: String) -> [[String]] {
        var options: [[String]] = []

        // NÃO_PRATICAR → PRATICAR NÃO (em Libras a negação costuma vir depois).
        if token.hasPrefix("NÃO_"), token.count > 4 {
            let verb = String(token.dropFirst(4))
            options.append([verb, "NÃO"])
            options.append(contentsOf: lemmas(of: verb).map { [$0, "NÃO"] })
        }

        // 1S_AJUDAR_2S → AJUDAR (verbos direcionais sem sinal próprio).
        let parts = token.split(separator: "_").map(String.init)
        if parts.count == 3, parts[0].first?.isNumber == true, parts[2].first?.isNumber == true {
            options.append([parts[1]])
        }

        // PESSOAL&PARTICULAR → PESSOAL.
        if let ampersand = token.firstIndex(of: "&") {
            options.append([String(token[..<ampersand])])
        }

        // BOA_NOITE → BOA NOITE (compostos genéricos).
        if parts.count == 2, !token.hasPrefix("NÃO_"), parts.allSatisfy({ $0.count > 1 && $0.allSatisfy(\.isLetter) }) {
            options.append(parts)
        }

        options.append(contentsOf: lemmas(of: token).map { [$0] })

        var seen = Set<[String]>()
        return options.filter { !$0.contains(token) && seen.insert($0).inserted }
    }

    /// Formas prováveis de dicionário para palavras que o tradutor não lematizou.
    static func lemmas(of word: String) -> [String] {
        guard word.count >= 4, word.allSatisfy({ $0.isLetter }) else { return [] }
        var result: [String] = []
        func add(_ candidate: String) {
            if candidate.count >= 3, candidate != word, !result.contains(candidate) { result.append(candidate) }
        }

        // DISCERNIRMOS / DISCERNIRMO → DISCERNIR (infinitivo pessoal).
        for suffix in ["RMOS", "RMO", "RDES", "REM"] where word.hasSuffix(suffix) {
            add(String(word.dropLast(suffix.count)) + "R")
        }
        // Gerúndio e particípio: FALANDO → FALAR, FALADO → FALAR.
        for (suffix, replacement) in [("ANDO", "AR"), ("ENDO", "ER"), ("INDO", "IR"), ("ADO", "AR"), ("IDO", "ER"), ("IDA", "ER"), ("ADA", "AR")]
            where word.hasSuffix(suffix) {
            add(String(word.dropLast(suffix.count)) + replacement)
        }
        // Letra duplicada por erro do tradutor: ADQUIRIIR → ADQUIRIR.
        let collapsed = word.reduce(into: "") { result, char in
            if result.last != char { result.append(char) }
        }
        if collapsed != word { add(collapsed) }
        // Plural: VEZES → VEZ, CASAS → CASA.
        if word.hasSuffix("ES") { add(String(word.dropLast(2))) }
        if word.hasSuffix("S") { add(String(word.dropLast())) }
        // Feminino: QUANTA → QUANTO, OBRIGADA → OBRIGADO.
        if word.hasSuffix("A") { add(String(word.dropLast()) + "O") }
        if word.hasSuffix("AS") { add(String(word.dropLast(2)) + "O") }
        return result
    }

    /// Todos os nomes que valem consultar no dicionário para otimizar esta glosa.
    public static func lookupNames(for tokens: [String], availability: [String: Bool]) -> [String] {
        var names: [String] = []
        for token in tokens where availability[token] == false {
            for option in alternatives(for: token) { names.append(contentsOf: option) }
        }
        return Array(Set(names)).sorted()
    }

    public static func optimize(_ tokens: [String], availability: [String: Bool], options: Options = Options()) -> Result {
        var output: [String] = []
        var removed: [String] = []
        var replaced: [String] = []
        var spelled: [String] = []

        func exists(_ name: String) -> Bool { availability[name] != false }
        func isMarker(_ token: String) -> Bool { token.hasPrefix("[") && token.hasSuffix("]") }

        for token in tokens where !token.isEmpty {
            if options.removePunctuationPauses, pauseMarkers.contains(token) {
                removed.append(token)
                continue
            }
            if options.removeFillers, fillers.contains(token) {
                removed.append(token)
                continue
            }

            var sequence = [token]
            if !isMarker(token), !exists(token) {
                if let alternative = alternatives(for: token).first(where: { $0.allSatisfy { availability[$0] == true } }) {
                    sequence = alternative
                    replaced.append("\(token)→\(alternative.joined(separator: " "))")
                } else {
                    let letters = token.filter { $0.isLetter || $0.isNumber }.count
                    let keep: Bool
                    switch options.unknownWords {
                    case .spell: keep = true
                    case .spellShort: keep = letters <= options.maxSpelledLetters
                    case .skip: keep = false
                    }
                    if !keep {
                        removed.append(token)
                        continue
                    }
                    spelled.append(token)
                }
            }

            for sign in sequence {
                // Repetição imediata (SENHOR SENHOR) só custa tempo.
                if output.last == sign {
                    removed.append(sign)
                } else {
                    output.append(sign)
                }
            }
        }

        return Result(tokens: output, removed: removed, replaced: replaced, spelled: spelled)
    }

    /// Glosa de emergência quando a API de tradução falha: sem artigos, preposições e conectivos,
    /// que não têm sinal próprio e seriam soletrados.
    public static func fallbackTokens(for text: String) -> [String] {
        let stopwords: Set<String> = [
            "O", "A", "OS", "AS", "UM", "UMA", "UNS", "UMAS", "DE", "DA", "DO", "DAS", "DOS", "EM", "NA", "NO", "NAS", "NOS",
            "POR", "PELA", "PELO", "PELAS", "PELOS", "PARA", "PRA", "PRO", "COM", "E", "OU", "QUE", "SE", "AO", "AOS", "À", "ÀS",
            "ME", "TE", "LHE", "NUM", "NUMA", "DUM", "DUMA",
        ]
        return GlossService.fallbackGloss(for: text)
            .split(separator: " ")
            .map(String.init)
            .filter { !stopwords.contains($0) }
    }

    /// Custo estimado em segundos para sinalizar os tokens na velocidade dada.
    public static func estimatedDuration(_ tokens: [String], availability: [String: Bool], speed: Double, costs: SigningCosts = SigningCosts()) -> TimeInterval {
        let speed = max(speed, 0.1)
        var seconds = costs.overheadPerPlay
        for (index, token) in tokens.enumerated() {
            if token.hasPrefix("[") {
                // No fim da glosa a pausa ocupa o lugar da volta ao descanso (medido: ~0 s a 2–3×).
                if index < tokens.count - 1 { seconds += costs.secondsPerMarker / speed }
            } else if availability[token] == false {
                // Datilologia acelera bem menos que os sinais.
                let letters = Double(token.filter { $0.isLetter || $0.isNumber }.count)
                seconds += letters * costs.secondsPerLetter / pow(speed, 0.6)
            } else {
                seconds += costs.secondsPerSign / speed
            }
        }
        return seconds
    }
}

/// Tempos do avatar do VLibras.
///
/// Chrome headless (Scripts/bench-avatar.mjs): 1 sinal 4,06 / 3,29 / 2,82 s (1× / 2× / 3×);
/// 4 sinais 11,99 / 6,83 / 5,07 s; 11 letras soletradas 10,65 / 7,75 / 6,22 s.
/// OBS em live real (23 envios de 1 a 23 sinais, 14/09/2026): duração ≈ 1,2 s + 1,84 s × sinais ÷ velocidade.
/// Os padrões ficam entre os dois, priorizando o OBS.
public struct SigningCosts: Sendable, Equatable, Codable {
    /// Transição de entrada e saída de cada envio; praticamente não diminui com a velocidade.
    public var overheadPerPlay: TimeInterval
    /// Por sinal em velocidade 1 (escala com 1/velocidade).
    public var secondsPerSign: TimeInterval
    /// Por letra soletrada em velocidade 1 (escala com 1/velocidade^0,6).
    public var secondsPerLetter: TimeInterval
    /// Pausa de pontuação no meio da sequência, em velocidade 1.
    public var secondsPerMarker: TimeInterval

    public init(overheadPerPlay: TimeInterval = 1.6, secondsPerSign: TimeInterval = 1.9, secondsPerLetter: TimeInterval = 0.6, secondsPerMarker: TimeInterval = 1.0) {
        self.overheadPerPlay = overheadPerPlay
        self.secondsPerSign = secondsPerSign
        self.secondsPerLetter = secondsPerLetter
        self.secondsPerMarker = secondsPerMarker
    }
}
