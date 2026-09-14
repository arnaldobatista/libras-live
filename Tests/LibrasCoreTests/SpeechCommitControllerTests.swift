import Foundation
import Testing
@testable import LibrasCore

@Suite struct SpeechCommitControllerTests {
    let t0 = Date(timeIntervalSince1970: 5_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// Níveis a 20 Hz entre dois instantes.
    func levels(_ c: inout SpeechCommitController, db: Float, from start: Double, to end: Double) {
        var time = start
        while time < end {
            c.level(db, at: at(time))
            time += 0.05
        }
    }

    @Test func doesNotCutWordsDuringContinuousSpeech() {
        // Reproduz a live: rajadas de hipótese a cada ~1 s, pessoa falando sem parar.
        var c = SpeechCommitController()
        levels(&c, db: -55, from: 0, to: 1)
        var commits: [SpeechCommitController.Commit] = []
        let bursts = ["em ambos os blocos", "em ambos os blocos parecem uma pilha", "em ambos os blocos parecem uma pilha gigante de multipl",
                      "em ambos os blocos parecem uma pilha gigante de multiplicações de matrizes"]
        var time = 1.0
        for burst in bursts {
            levels(&c, db: -22, from: time, to: time + 1.05)
            commits += c.partial(burst, at: at(time + 1.05))
            for step in stride(from: time + 1.05, to: time + 2.1, by: 0.2) { commits += c.tick(at: at(step)) }
            time += 1.05
        }
        // Pode confirmar o prefixo estável, mas nunca uma palavra cortada, e nada se perde.
        #expect(commits.allSatisfy { !$0.text.contains("multipl") })
        let everything = (commits.map(\.text) + [c.pendingText]).joined(separator: " ")
        #expect(everything == bursts.last)
    }

    @Test func commitsWholePhraseAfterRealPause() {
        var c = SpeechCommitController()
        levels(&c, db: -55, from: 0, to: 1)
        levels(&c, db: -20, from: 1, to: 3)
        _ = c.partial("Jesus não está lá", at: at(3))
        levels(&c, db: -55, from: 3, to: 4.5)

        let early = c.tick(at: at(3.8))  // silêncio 0,8 s, hipótese parada 0,8 s < 1,2 s
        #expect(early.isEmpty)
        let commits = c.tick(at: at(4.4))
        #expect(commits.map(\.text) == ["Jesus não está lá"])
        #expect(commits.first?.source == .silence)
        #expect(c.tick(at: at(4.6)).isEmpty)
    }

    @Test func finalAfterPauseDoesNotRepeat() {
        var c = SpeechCommitController()
        levels(&c, db: -55, from: 0, to: 1)
        levels(&c, db: -20, from: 1, to: 2)
        _ = c.partial("Amém", at: at(2))
        levels(&c, db: -55, from: 2, to: 4)
        #expect(c.tick(at: at(3.5)).map(\.text) == ["Amém"])
        #expect(c.final("Amém.").isEmpty)
    }

    @Test func stalledHypothesisCommitsUnderNoise() {
        var c = SpeechCommitController()
        // Música/fala de fundo oscilando: o áudio nunca fica em silêncio.
        var time = 0.0
        while time < 5 {
            c.level(time.truncatingRemainder(dividingBy: 0.2) < 0.1 ? -18 : -30, at: at(time))
            time += 0.05
        }
        _ = c.partial("obrigado a todos", at: at(1))
        #expect(c.tick(at: at(3)).isEmpty)
        #expect(c.tick(at: at(3.6)).first?.source == .stalled)
    }

    @Test func stableSentenceStillCommitsImmediately() {
        var c = SpeechCommitController()
        let commits = c.partial("Boa noite, pessoal. Sejam", at: at(1))
        #expect(commits.map(\.source) == [.stable])
    }

    @Test func stopCommitsRemainder() {
        var c = SpeechCommitController()
        _ = c.partial("prever o que vem a seguir", at: at(1))
        #expect(c.stop().map(\.text) == ["prever o que vem a seguir"])
        #expect(c.pendingText.isEmpty)
    }
}
