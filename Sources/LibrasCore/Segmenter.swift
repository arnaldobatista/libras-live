import Foundation

/// Quebra o texto transcrito em trechos curtos para tradução.
///
/// Trechos curtos começam a ser sinalizados mais cedo, o que reduz a latência
/// percebida. A quebra acontece em fim de frase e, quando a frase é longa,
/// preferencialmente depois de uma vírgula.
public struct Segmenter: Sendable, Equatable {
    public var maxWords: Int

    public init(maxWords: Int = 14) {
        self.maxWords = max(3, maxWords)
    }

    public func split(_ text: String) -> [String] {
        sentences(in: text)
            .flatMap(chunks(of:))
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", ";"]

    private func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)

        for (index, char) in chars.enumerated() {
            current.append(char)
            guard Self.sentenceEnders.contains(char) else { continue }
            let next = index + 1 < chars.count ? chars[index + 1] : " "
            if next.isWhitespace {
                result.append(current)
                current = ""
            }
        }
        result.append(current)

        return result
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
    }

    private func chunks(of sentence: String) -> [String] {
        let words = sentence.split(separator: " ").map(String.init)
        guard words.count > maxWords else { return [sentence] }

        var result: [String] = []
        var start = 0

        while start < words.count {
            let remaining = words.count - start
            // Evita sobrar um rabo de 1–2 palavras isoladas.
            if remaining <= maxWords + 2 {
                result.append(words[start...].joined(separator: " "))
                break
            }

            let limit = start + maxWords
            let minCut = start + maxWords / 2
            var cut = limit
            for index in stride(from: limit - 1, through: minCut, by: -1) {
                if let last = words[index].last, last == "," || last == ":" {
                    cut = index + 1
                    break
                }
            }

            result.append(words[start..<cut].joined(separator: " "))
            start = cut
        }

        return result
    }
}
