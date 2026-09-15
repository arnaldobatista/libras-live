import Foundation
import Testing
@testable import LibrasCore

@Suite struct RewritePromptTests {
    @Test func includesModeContextAndTrecho() {
        let prompt = RewritePrompt.make(text: "  quando um desses chatspots gera uma palavra ", mode: .faithful, context: ["Mas em linhas gerais,", " "])
        #expect(prompt.system.contains("Modo fiel"))
        #expect(prompt.user.hasPrefix("Contexto (frases anteriores"))
        #expect(prompt.user.hasSuffix("Trecho:\nquando um desses chatspots gera uma palavra"))
        #expect(prompt.temperature < 0.2)
    }

    @Test func omitsEmptyContext() {
        let prompt = RewritePrompt.make(text: "Bom dia a todos.", mode: .rewrite, context: [])
        #expect(prompt.user == "Trecho:\nBom dia a todos.")
        #expect(prompt.system.contains("Modo nova versão"))
    }

    @Test func limitsTokensByLength() {
        let short = RewritePrompt.make(text: "Oi.", mode: .balanced)
        let long = RewritePrompt.make(text: Array(repeating: "palavra", count: 200).joined(separator: " "), mode: .balanced)
        #expect(short.maxTokens < 40)
        #expect(long.maxTokens == 240)
    }
}

@Suite struct RewriteValidatorTests {
    @Test func cleansLabelsQuotesAndThinking() {
        #expect(RewriteValidator.clean("<think>pensando</think>\n**Trecho revisado:** \"Bom dia a todos.\"") == "Bom dia a todos.")
        #expect(RewriteValidator.clean("Texto:\n  primeira linha\nsegunda linha ") == "primeira linha segunda linha")
    }

    @Test func acceptsFaithfulCorrection() {
        let outcome = RewriteValidator.validate(
            original: "interpretando e expandindo os detalhes de cada eta.",
            output: "interpretando e expandindo os detalhes de cada etapa.",
            mode: .faithful
        )
        #expect(outcome == .accepted("interpretando e expandindo os detalhes de cada etapa.", changed: true))
    }

    @Test func marksUnchanged() {
        let outcome = RewriteValidator.validate(original: "Bom dia, pessoal.", output: "bom dia pessoal", mode: .faithful)
        #expect(outcome == .accepted("bom dia pessoal", changed: false))
    }

    @Test func rejectsInventedContent() {
        let outcome = RewriteValidator.validate(
            original: "Essas peças são chamadas de tokens.",
            output: "Hoje o culto começa às dezenove horas com louvor.",
            mode: .balanced
        )
        #expect(outcome == .rejected(reason: "mudou o sentido"))
    }

    @Test func rejectsChatterAndLongAnswers() {
        #expect(RewriteValidator.validate(original: "Bom dia.", output: "Aqui está o trecho: Bom dia.", mode: .faithful) == .rejected(reason: "resposta fora do formato"))
        let long = Array(repeating: "palavras novas", count: 10).joined(separator: " ")
        #expect(RewriteValidator.validate(original: "Bom dia a todos.", output: long, mode: .faithful) == .rejected(reason: "resposta longa demais"))
        #expect(RewriteValidator.validate(original: "texto", output: "   ", mode: .rewrite) == .rejected(reason: "resposta vazia"))
    }

    @Test func rewriteModeAllowsReorganizing() {
        let outcome = RewriteValidator.validate(
            original: "então assim, o que a gente vai fazer hoje é conversar sobre como os dados fluem num transformador",
            output: "Hoje vamos conversar. Os dados fluem num transformador.",
            mode: .rewrite
        )
        guard case .accepted(_, let changed) = outcome else {
            Issue.record("esperava aceitar: \(outcome)")
            return
        }
        #expect(changed)
    }

    @Test func matchesInflections() {
        #expect(PhraseText.sameRoot("transformador", "transformadores"))
        #expect(PhraseText.sameRoot("falamos", "falar"))
        #expect(!PhraseText.sameRoot("casa", "cachorro"))
    }
}

@Suite struct RewriteBufferTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func sentenceModeJoinsFragmentsUntilPeriod() {
        var buffer = RewriteBuffer(grouping: RewriteGrouping(mode: .sentence, words: 30))
        #expect(buffer.append("Recebemos um tribunal que atravessou crises,", source: "estável", at: start).isEmpty)
        #expect(buffer.append("autoritarismos, ameaças em determinados", source: "estável", at: start.addingTimeInterval(4)).isEmpty)
        let units = buffer.append("momentos essa instituição pagou um preço.", source: "final", at: start.addingTimeInterval(8))
        #expect(units.map(\.text) == ["Recebemos um tribunal que atravessou crises, autoritarismos, ameaças em determinados momentos essa instituição pagou um preço."])
        #expect(units.first?.startedAt == start)
        #expect(units.first?.sources == ["estável", "final"])
        #expect(buffer.isEmpty)
    }

    @Test func sentenceModeMergesShortSentencesAndKeepsRemainder() {
        var buffer = RewriteBuffer(grouping: RewriteGrouping(mode: .sentence, words: 30))
        #expect(buffer.append("Uma responsabilidade.", source: "estável", at: start).isEmpty)
        let units = buffer.append("memória, portanto, é responsabilidade. Recebemos um", source: "estável", at: start.addingTimeInterval(3))
        #expect(units.map(\.text) == ["Uma responsabilidade. memória, portanto, é responsabilidade."])
        #expect(buffer.pendingText == "Recebemos um")
    }

    @Test func sentenceModeCutsAtCommaWhenPeriodNeverComes() {
        // Limite de 10 palavras com folga de 3 para terminar na vírgula.
        var buffer = RewriteBuffer(grouping: RewriteGrouping(mode: .sentence, words: 10))
        #expect(buffer.append("e que tenhamos presente que ao final", source: "estável", at: start).isEmpty)
        let units = buffer.append("não será a posição, de qualquer de nós", source: "estável", at: start)
        #expect(units.map(\.text) == ["e que tenhamos presente que ao final não será a posição,"])
        #expect(buffer.pendingText == "de qualquer de nós")
    }

    @Test func wordsModeWaitsForPeriodWithinExtraWords() {
        var buffer = RewriteBuffer(grouping: RewriteGrouping(mode: .words, words: 8, extraWords: 5))
        // Ponto antes de juntar 8 palavras não fecha.
        #expect(buffer.append("Isso não significa ausência.", source: "estável", at: start).isEmpty)
        #expect(buffer.append("O Supremo existe para que", source: "estável", at: start).isEmpty)
        // Passou de 8 sem ponto: espera o ponto até 13 palavras.
        let units = buffer.append("teses possam ser debatidas. E depois", source: "estável", at: start)
        #expect(units.map(\.text) == ["Isso não significa ausência. O Supremo existe para que teses possam ser debatidas."])
        #expect(buffer.pendingText == "E depois")
    }

    @Test func wordsModeCutsAtLimitPreferringComma() {
        var buffer = RewriteBuffer(grouping: RewriteGrouping(mode: .words, words: 6, extraWords: 3))
        let units = buffer.append("um dois três quatro cinco seis, sete oito nove dez onze", source: "estável", at: start)
        #expect(units.map(\.text) == ["um dois três quatro cinco seis,"])
        #expect(buffer.pendingText == "sete oito nove dez onze")
        let noComma = buffer.append("doze treze quatorze quinze", source: "estável", at: start)
        #expect(noComma.map(\.text) == ["sete oito nove dez onze doze treze quatorze quinze"])
    }

    @Test func pauseInSpeechClosesUnit() {
        var buffer = RewriteBuffer(grouping: RewriteGrouping(mode: .sentence, words: 30, pauseSeconds: 2))
        _ = buffer.append("e no caso de texto tendem a ser palavras", source: "estável", at: start)
        // Pedaços chegam a cada ~4 s na fala corrida: sem silêncio no áudio, não fecha.
        #expect(buffer.tick(at: start.addingTimeInterval(4), silence: 0.2) == nil)
        // Silêncio de 2 s e 1 s sem pedaço novo: fecha.
        #expect(buffer.tick(at: start.addingTimeInterval(4.5), silence: 2.1)?.text == "e no caso de texto tendem a ser palavras")
    }

    @Test func withoutDetectorUsesTimeSinceLastPiece() {
        var buffer = RewriteBuffer(grouping: RewriteGrouping(pauseSeconds: 2))
        _ = buffer.append("texto digitado sem ponto", source: "api", at: start)
        #expect(buffer.tick(at: start.addingTimeInterval(1.5)) == nil)
        #expect(buffer.tick(at: start.addingTimeInterval(2.1))?.text == "texto digitado sem ponto")
    }

    @Test func closesWhenWaitingTooLong() {
        var buffer = RewriteBuffer(grouping: RewriteGrouping(mode: .sentence, words: 30))
        _ = buffer.append("uma fala que nunca termina", source: "estável", at: start)
        #expect(buffer.tick(at: start.addingTimeInterval(20), silence: 0) == nil)
        #expect(buffer.tick(at: start.addingTimeInterval(38), silence: 0)?.text == "uma fala que nunca termina")
    }

    @Test func decodesOldAndPartialSettings() throws {
        let grouping = try JSONDecoder().decode(RewriteGrouping.self, from: Data(#"{"mode":"words","words":18}"#.utf8))
        #expect(grouping.mode == .words)
        #expect(grouping.words == 18)
        #expect(grouping.extraWords == 6)
        #expect(grouping.pauseSeconds == 2)
    }

    @Test func ignoresPunctuationOnlyPieces() {
        var buffer = RewriteBuffer()
        #expect(buffer.append(".", source: "estável", at: start).isEmpty)
        #expect(buffer.flush()?.text == ".")
        #expect(buffer.append("  ", source: "estável", at: start).isEmpty)
        #expect(buffer.flush() == nil)
    }
}
