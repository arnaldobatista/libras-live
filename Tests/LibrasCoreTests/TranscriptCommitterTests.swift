import Foundation
import Testing
@testable import LibrasCore

@Suite struct TranscriptCommitterTests {
    @Test func waitsUntilRecognizerMovesOn() {
        var c = TranscriptCommitter(minFollowingWords: 2)
        #expect(c.partial("Boa noite, pessoal.").isEmpty)
        #expect(c.partial("Boa noite, pessoal. Sejam").isEmpty)
        #expect(c.partial("Boa noite, pessoal. Sejam todos") == ["Boa noite, pessoal."])
        #expect(c.pending(in: "Boa noite, pessoal. Sejam todos") == "Sejam todos")
    }

    @Test func doesNotRepeatCommittedSentences() {
        var c = TranscriptCommitter(minFollowingWords: 2)
        _ = c.partial("Oi. Tudo bem com você?")
        #expect(c.partial("Oi. Tudo bem com você? Eu estou").isEmpty == false)
        #expect(c.partial("Oi. Tudo bem com você? Eu estou bem").isEmpty)
    }

    @Test func commitsSeveralSentencesAtOnce() {
        var c = TranscriptCommitter(minFollowingWords: 2)
        let committed = c.partial("Um dois. Três quatro! Cinco seis sete")
        #expect(committed == ["Um dois.", "Três quatro!"])
    }

    @Test func finalEmitsOnlyRemainder() {
        var c = TranscriptCommitter(minFollowingWords: 2)
        _ = c.partial("Boa noite, pessoal. Sejam todos bem-vindos")
        #expect(c.final("Boa noite, pessoal. Sejam todos bem-vindos à live") == ["Sejam todos bem-vindos à live"])
        #expect(c.committedWords == 0)
    }

    @Test func finalWithoutPartialsEmitsEverything() {
        var c = TranscriptCommitter()
        #expect(c.final("Obrigado a todos.") == ["Obrigado a todos."])
    }

    @Test func finalAlreadyCommittedEmitsNothing() {
        var c = TranscriptCommitter(minFollowingWords: 1)
        _ = c.partial("Frase um. Frase")
        #expect(c.final("Frase um.") == [])
    }

    @Test func chunksLongSpeechWithoutPunctuation() {
        var c = TranscriptCommitter(minFollowingWords: 2, maxPendingWords: 14, chunkWords: 8)
        let words = (1...13).map { "p\($0)" }.joined(separator: " ")
        #expect(c.partial(words).isEmpty)

        let longer = (1...14).map { "p\($0)" }.joined(separator: " ")
        #expect(c.partial(longer) == ["p1 p2 p3 p4 p5 p6 p7 p8"])
        #expect(c.pending(in: longer) == "p9 p10 p11 p12 p13 p14")
    }

    @Test func chunkPrefersComma() {
        var c = TranscriptCommitter(minFollowingWords: 2, maxPendingWords: 14, chunkWords: 8)
        let text = "a b c d e, f g h i j k l m n"
        #expect(c.partial(text) == ["a b c d e,"])
    }

    @Test func survivesShrinkingHypothesis() {
        var c = TranscriptCommitter(minFollowingWords: 1)
        _ = c.partial("Um. Dois três quatro")
        #expect(c.committedWords == 1)
        #expect(c.partial("").isEmpty)
        #expect(c.committedWords == 0)
    }
}

@Suite struct TranscriptCommitterClauseTests {
    @Test func commitsLongClauseAtComma() {
        var c = TranscriptCommitter(minFollowingWords: 1, commaMinWords: 6)
        #expect(c.partial("Porque nós temos uma dificuldade grande, e").isEmpty == false)
        #expect(c.pending(in: "Porque nós temos uma dificuldade grande, e") == "e")
    }

    @Test func ignoresShortClause() {
        var c = TranscriptCommitter(minFollowingWords: 1, commaMinWords: 6)
        #expect(c.partial("Os corações, que não").isEmpty)
    }

    @Test func commaCommitCanBeDisabled() {
        var c = TranscriptCommitter(minFollowingWords: 1, commaMinWords: 0)
        #expect(c.partial("um dois três quatro cinco seis sete, oito").isEmpty)
    }

    @Test func handlesRepeatedWordsBeforeComma() {
        var c = TranscriptCommitter(minFollowingWords: 1, commaMinWords: 3)
        let committed = c.partial("senhor senhor, senhor senhor senhor, fim")
        #expect(committed == ["senhor senhor, senhor senhor senhor,"])
    }

    @Test func flushCommitsPendingOnPause() {
        var c = TranscriptCommitter()
        #expect(c.partial("Jesus não está lá").isEmpty)
        #expect(c.flush("Jesus não está lá") == ["Jesus não está lá"])
        #expect(c.flush("Jesus não está lá").isEmpty)
        // Final igual ao que já saiu não repete.
        #expect(c.final("Jesus não está lá.").isEmpty)
        #expect(c.committedWords == 0)
    }

    @Test func flushThenContinueOnlyEmitsNewWords() {
        var c = TranscriptCommitter()
        _ = c.flush("Se é o dinheiro")
        #expect(c.pending(in: "Se é o dinheiro Jesus não está lá") == "Jesus não está lá")
        #expect(c.final("Se é o dinheiro Jesus não está lá.") == ["Jesus não está lá."])
    }
}

@Suite struct TranscriptCommitterStreamingTests {
    let t0 = Date(timeIntervalSince1970: 9_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func streamsStablePrefixWithoutPunctuation() {
        var c = TranscriptCommitter(streamChunkWords: 4, streamTrailingWords: 2, streamStableSeconds: 1)
        #expect(c.partial("os dados fluem entre blocos", at: at(0)).isEmpty)
        #expect(c.partial("os dados fluem entre blocos de atenção", at: at(0.5)).isEmpty)
        // Em 1,1 s as 5 primeiras estão estáveis; ficam 2 no fim → confirma "os dados fluem entre blocos".
        let committed = c.partial("os dados fluem entre blocos de atenção", at: at(1.1))
        #expect(committed == ["os dados fluem entre blocos"])
        #expect(c.pending(in: "os dados fluem entre blocos de atenção") == "de atenção")
    }

    @Test func neverCommitsIncompleteTail() {
        var c = TranscriptCommitter(streamChunkWords: 2, streamTrailingWords: 2, streamStableSeconds: 1)
        _ = c.partial("uma pilha gigante de mult", at: at(0))
        let committed = c.partial("uma pilha gigante de mult", at: at(5))
        #expect(committed == ["uma pilha gigante"])
        #expect(c.pending(in: "uma pilha gigante de mult") == "de mult")
    }

    @Test func revisionResetsStability() {
        var c = TranscriptCommitter(streamChunkWords: 3, streamTrailingWords: 1, streamStableSeconds: 1)
        _ = c.partial("parecem uma pilha gigante", at: at(0))
        // Reconhecedor revisa a segunda palavra em 0,9 s: estabilidade recomeça dali.
        _ = c.partial("parecem-lhe duma pilha gigante", at: at(0.9))
        #expect(c.partial("parecem-lhe duma pilha gigante", at: at(1.2)).isEmpty)
        #expect(c.partial("parecem-lhe duma pilha gigante", at: at(2.0)) == ["parecem-lhe duma pilha"])
    }

    @Test func streamingCanBeDisabled() {
        var c = TranscriptCommitter(streamChunkWords: 0)
        _ = c.partial("um dois três quatro cinco seis sete oito", at: at(0))
        #expect(c.partial("um dois três quatro cinco seis sete oito", at: at(10)).isEmpty)
    }
}
