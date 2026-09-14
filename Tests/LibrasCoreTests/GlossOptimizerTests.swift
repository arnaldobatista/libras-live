import Testing
@testable import LibrasCore

@Suite struct GlossOptimizerTests {
    func tokens(_ gloss: String) -> [String] { gloss.split(separator: " ").map(String.init) }

    @Test func removesPausesAndRepetitions() {
        let result = GlossOptimizer.optimize(tokens("VOCÊS CHAMAR&NOMEAR SENHOR SENHOR [PONTO]"), availability: [:])
        #expect(result.gloss == "VOCÊS CHAMAR&NOMEAR SENHOR")
        #expect(result.removed == ["SENHOR", "[PONTO]"])
    }

    @Test func keepsQuestionMarker() {
        let result = GlossOptimizer.optimize(tokens("QUEM SENHOR SUA VIDA [INTERROGAÇÃO]"), availability: [:])
        #expect(result.gloss == "QUEM SENHOR SUA VIDA [INTERROGAÇÃO]")
    }

    @Test func splitsMissingNegationCompound() {
        let availability = ["NÃO_PRATICAR": false, "PRATICAR": true, "NÃO": true]
        let result = GlossOptimizer.optimize(tokens("FALAR HOMEM OUVIR PALAVRA NÃO_PRATICAR"), availability: availability)
        #expect(result.gloss == "FALAR HOMEM OUVIR PALAVRA PRATICAR NÃO")
        #expect(result.replaced == ["NÃO_PRATICAR→PRATICAR NÃO"])
    }

    @Test func keepsExistingCompound() {
        let availability = ["NÃO_PODER": true]
        #expect(GlossOptimizer.optimize(tokens("JESUS NÃO_PODER"), availability: availability).gloss == "JESUS NÃO_PODER")
    }

    @Test func lemmatizesMisconjugatedWords() {
        let availability = ["DISCERNIRMO": false, "DISCERNIR": true, "QUANTA": false, "QUANTO": true]
        let result = GlossOptimizer.optimize(tokens("QUANTA VEZ DISCERNIRMO"), availability: availability)
        #expect(result.gloss == "QUANTO VEZ DISCERNIR")
    }

    @Test func unknownWordPolicies() {
        let availability = ["DISCERNIRMO": false, "PAULO": false]
        let text = tokens("PAULO DISCERNIRMO JESUS")

        let spell = GlossOptimizer.optimize(text, availability: availability, options: .init(unknownWords: .spell))
        #expect(spell.gloss == "PAULO DISCERNIRMO JESUS")
        #expect(spell.spelled == ["PAULO", "DISCERNIRMO"])

        let short = GlossOptimizer.optimize(text, availability: availability, options: .init(unknownWords: .spellShort, maxSpelledLetters: 6))
        #expect(short.gloss == "PAULO JESUS")
        #expect(short.removed == ["DISCERNIRMO"])

        let skip = GlossOptimizer.optimize(text, availability: availability, options: .init(unknownWords: .skip))
        #expect(skip.gloss == "JESUS")
    }

    @Test func unknownAvailabilityIsTrusted() {
        #expect(GlossOptimizer.optimize(tokens("PALAVRA_NOVA"), availability: [:]).gloss == "PALAVRA_NOVA")
    }

    @Test func removesFillersOnlyWhenAsked() {
        let gloss = tokens("ENTÃO AQUI JESUS ELE INSTRUIR")
        #expect(GlossOptimizer.optimize(gloss, availability: [:]).gloss == "ENTÃO AQUI JESUS ELE INSTRUIR")
        #expect(GlossOptimizer.optimize(gloss, availability: [:], options: .init(removeFillers: true)).gloss == "AQUI JESUS ELE INSTRUIR")
    }

    @Test func alternativesForCompounds() {
        #expect(GlossOptimizer.alternatives(for: "1S_AJUDAR_2S").first == ["AJUDAR"])
        #expect(GlossOptimizer.alternatives(for: "PESSOAL&PARTICULAR").first == ["PESSOAL"])
        #expect(GlossOptimizer.alternatives(for: "NÃO_LÁ").first == ["LÁ", "NÃO"])
    }

    @Test func lookupNamesOnlyForMissing() {
        let names = GlossOptimizer.lookupNames(for: ["CASA", "NÃO_PRATICAR"], availability: ["CASA": true, "NÃO_PRATICAR": false])
        #expect(names.contains("PRATICAR"))
        #expect(names.contains("NÃO"))
        #expect(!names.contains("CASA"))
    }

    @Test func fallbackDropsFunctionWords() {
        let result = GlossOptimizer.fallbackTokens(for: "frase de sinais que ainda não estiver no cash depende da internet.")
        #expect(result == ["FRASE", "SINAIS", "AINDA", "NÃO", "ESTIVER", "CASH", "DEPENDE", "INTERNET"])
    }

    @Test func estimatesDurationWithOverheadAndSpelling() {
        let costs = SigningCosts(overheadPerPlay: 2, secondsPerSign: 2, secondsPerLetter: 1, secondsPerMarker: 1)
        let oneSign = GlossOptimizer.estimatedDuration(["CASA"], availability: [:], speed: 2, costs: costs)
        #expect(oneSign == 3)  // 2 fixos + 2/2
        let spelled = GlossOptimizer.estimatedDuration(["ABC"], availability: ["ABC": false], speed: 1, costs: costs)
        #expect(spelled == 5)  // 2 fixos + 3 letras × 1
    }

    @Test func defaultCostsMatchMeasurements() {
        // Headless: 4 sinais a 2× = 6,83 s. OBS em live: 21 sinais a 3× ≈ 14,3 s; 13 sinais a 2,6× = 10,7 s.
        let four = GlossOptimizer.estimatedDuration(Array(repeating: "A", count: 4).enumerated().map { "A\($0.offset)" }, availability: [:], speed: 2)
        let long = GlossOptimizer.estimatedDuration((0..<21).map { "S\($0)" }, availability: [:], speed: 3)
        let medium = GlossOptimizer.estimatedDuration((0..<13).map { "S\($0)" }, availability: [:], speed: 2.6)
        #expect(abs(four - 6.83) < 1.5)
        #expect(abs(long - 14.3) < 1.5)
        #expect(abs(medium - 10.7) < 1.5)
    }

    @Test func collapsesDoubledLetters() {
        #expect(GlossOptimizer.alternatives(for: "ADQUIRIIR").contains(["ADQUIRIR"]))
    }
}
