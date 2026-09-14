import Foundation

/// Confirma trechos do texto provisório antes do reconhecedor finalizar.
///
/// O `SpeechTranscriber` só marca o resultado como final depois de uma pausa longa;
/// com fala contínua isso pode levar dezenas de segundos. Aqui um trecho é confirmado
/// quando já está estável na hipótese provisória:
///
/// - uma frase terminada em `.`, `!` ou `?` seguida de pelo menos `minFollowingWords`
///   palavras (o reconhecedor já seguiu adiante); ou
/// - uma oração terminada em vírgula com pelo menos `commaMinWords` palavras, seguida de
///   `minFollowingWords` palavras (0 desliga);
/// - fala corrida sem pontuação: palavras que não mudam há `streamStableSeconds` e já têm
///   `streamTrailingWords` palavras depois saem em blocos de pelo menos `streamChunkWords`
///   (a palavra final da hipótese pode estar incompleta, por isso nunca entra);
/// - fala longa sem pontuação: com `maxPendingWords` pendentes, confirma as primeiras
///   `chunkWords` (cortando na última vírgula, se houver);
/// - pausa de quem fala: `flush` confirma tudo o que estiver pendente.
///
/// Quando chega o resultado final, só a parte ainda não confirmada é emitida.
public struct TranscriptCommitter: Sendable, Equatable {
    public var minFollowingWords: Int
    public var maxPendingWords: Int
    public var chunkWords: Int
    public var commaMinWords: Int
    public var streamChunkWords: Int
    public var streamTrailingWords: Int
    public var streamStableSeconds: TimeInterval

    /// Palavras da hipótese atual já confirmadas.
    public private(set) var committedWords = 0

    /// Palavras da última hipótese e desde quando cada posição tem o valor atual.
    private var trackedWords: [String] = []
    private var stableSince: [Date] = []

    public init(
        minFollowingWords: Int = 1,
        maxPendingWords: Int = 20,
        chunkWords: Int = 12,
        commaMinWords: Int = 6,
        streamChunkWords: Int = 6,
        streamTrailingWords: Int = 3,
        streamStableSeconds: TimeInterval = 1.2
    ) {
        self.minFollowingWords = max(1, minFollowingWords)
        self.commaMinWords = max(0, commaMinWords)
        self.streamChunkWords = max(0, streamChunkWords)
        self.streamTrailingWords = max(1, streamTrailingWords)
        self.streamStableSeconds = streamStableSeconds
        self.chunkWords = max(3, chunkWords)
        self.maxPendingWords = max(self.chunkWords + 1, maxPendingWords)
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]

    /// Processa uma hipótese provisória e devolve os trechos confirmados agora.
    public mutating func partial(_ text: String, at now: Date = Date()) -> [String] {
        let words = Self.words(text)
        // A hipótese pode encolher numa revisão; nunca confirma além do que existe.
        committedWords = min(committedWords, words.count)
        track(words, at: now)

        var committed: [String] = []

        while true {
            let start = committedWords
            var end: Int?
            for index in start..<words.count {
                let word = words[index]
                if Self.endsSentence(word) || (commaMinWords > 0 && word.hasSuffix(",") && index - start + 1 >= commaMinWords) {
                    end = index
                    break
                }
            }
            guard let end, words.count - (end + 1) >= minFollowingWords else { break }
            committed.append(words[start...end].joined(separator: " "))
            committedWords = end + 1
        }

        // Prefixo estável da fala corrida.
        while streamChunkWords > 0 {
            let start = committedWords
            let lastAllowed = words.count - streamTrailingWords - 1
            var end = start - 1
            while end + 1 <= lastAllowed, now.timeIntervalSince(stableSince[end + 1]) >= streamStableSeconds {
                end += 1
            }
            guard end - start + 1 >= streamChunkWords else { break }
            var cut = end
            for index in stride(from: end, through: start + streamChunkWords / 2, by: -1) where words[index].hasSuffix(",") {
                cut = index
                break
            }
            committed.append(words[start...cut].joined(separator: " "))
            committedWords = cut + 1
        }

        while words.count - committedWords >= maxPendingWords {
            let start = committedWords
            let limit = start + chunkWords
            var cut = limit
            for index in stride(from: limit - 1, through: start + chunkWords / 2, by: -1) where words[index].hasSuffix(",") {
                cut = index + 1
                break
            }
            committed.append(words[start..<cut].joined(separator: " "))
            committedWords = cut
        }

        return committed
    }

    /// Processa o resultado final: devolve o que faltava confirmar e zera o estado.
    public mutating func final(_ text: String) -> [String] {
        let words = Self.words(text)
        defer {
            committedWords = 0
            trackedWords = []
            stableSince = []
        }
        guard committedWords < words.count else { return [] }
        return [words[committedWords...].joined(separator: " ")]
    }

    /// Pausa na fala: confirma tudo o que está pendente, sem zerar o estado (o resultado
    /// final que vier depois só emite palavras novas).
    public mutating func flush(_ text: String) -> [String] {
        let words = Self.words(text)
        guard committedWords < words.count else { return [] }
        let remainder = words[committedWords...].joined(separator: " ")
        committedWords = words.count
        return [remainder]
    }

    /// Parte da hipótese ainda não confirmada (para mostrar como prévia).
    public func pending(in text: String) -> String {
        let words = Self.words(text)
        guard committedWords < words.count else { return "" }
        return words[committedWords...].joined(separator: " ")
    }

    public mutating func reset() {
        committedWords = 0
        trackedWords = []
        stableSince = []
    }

    private mutating func track(_ words: [String], at now: Date) {
        var since: [Date] = []
        since.reserveCapacity(words.count)
        for (index, word) in words.enumerated() {
            if index < trackedWords.count, trackedWords[index] == word {
                since.append(stableSince[index])
            } else {
                since.append(now)
            }
        }
        trackedWords = words
        stableSince = since
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return sentenceEnders.contains(last)
    }
}
