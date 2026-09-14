import Testing
@testable import LibrasCore

@Suite struct SegmenterTests {
    @Test func splitsSentences() {
        let segments = Segmenter().split("Bom dia pessoal. Hoje vamos falar de tecnologia! Tudo bem?")
        #expect(segments == ["Bom dia pessoal.", "Hoje vamos falar de tecnologia!", "Tudo bem?"])
    }

    @Test func keepsDecimalsAndAbbreviationsWithoutSpace() {
        #expect(Segmenter().split("O valor é 3.5 reais hoje") == ["O valor é 3.5 reais hoje"])
    }

    @Test func normalizesWhitespace() {
        #expect(Segmenter().split("  olá \n  mundo  ") == ["olá mundo"])
    }

    @Test func dropsPunctuationOnlySegments() {
        #expect(Segmenter().split("... ! Oi.") == ["Oi."])
    }

    @Test func chunksLongSentencePreferringComma() {
        let text = "hoje nós vamos conversar sobre muitas coisas, principalmente sobre acessibilidade e sobre como incluir pessoas surdas nas transmissões ao vivo"
        let segments = Segmenter(maxWords: 10).split(text)
        #expect(segments.first == "hoje nós vamos conversar sobre muitas coisas,")
        #expect(segments.allSatisfy { $0.split(separator: " ").count <= 12 })
        #expect(segments.joined(separator: " ") == text)
    }

    @Test func hardCutsWithoutComma() {
        let words = (1...30).map { "p\($0)" }
        let segments = Segmenter(maxWords: 10).split(words.joined(separator: " "))
        #expect(segments.count == 3)
        #expect(segments[0].split(separator: " ").count == 10)
    }

    @Test func avoidsTinyTail() {
        let words = (1...11).map { "p\($0)" }
        #expect(Segmenter(maxWords: 10).split(words.joined(separator: " ")).count == 1)
    }
}
