import Foundation
import Testing
@testable import LibrasCore

@Suite struct BacklogPolicyTests {
    let policy = BacklogPolicy(baseSpeed: 1, maxSpeed: 2, speedUpAfter: 5, dropAfter: 15)

    @Test func normalSpeedBelowThreshold() {
        #expect(policy.speed(forLag: 0) == 1)
        #expect(policy.speed(forLag: 5) == 1)
    }

    @Test func interpolatesSpeed() {
        #expect(policy.speed(forLag: 10) == 1.5)
    }

    @Test func capsAtMaxSpeed() {
        #expect(policy.speed(forLag: 15) == 2)
        #expect(policy.speed(forLag: 60) == 2)
    }

    @Test func decodesOldPreferencesWithDefaults() throws {
        let json = #"{"baseSpeed":2,"maxSpeed":3,"speedUpAfter":5,"dropAfter":15,"secondsPerWord":0.8}"#
        let decoded = try JSONDecoder().decode(BacklogPolicy.self, from: Data(json.utf8))
        #expect(decoded.baseSpeed == 2)
        #expect(decoded.maxSpeed == 3)
        #expect(decoded.mergePhrases == true)
        #expect(decoded.maxBatchSeconds == 20)
    }
}

@Suite struct SignSchedulerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func scheduler(merge: Bool = true, maxBatch: TimeInterval = 12, repeats: Bool = true) -> SignScheduler {
        SignScheduler(
            policy: BacklogPolicy(baseSpeed: 1, maxSpeed: 2, speedUpAfter: 5, dropAfter: 15, secondsPerWord: 0.8,
                                  mergePhrases: merge, maxBatchSeconds: maxBatch, dropRepeats: repeats),
            costs: SigningCosts(overheadPerPlay: 2, secondsPerSign: 1, secondsPerLetter: 0.5, secondsPerMarker: 1)
        )
    }

    @Test func waitsForOverlayAndGloss() {
        var s = scheduler()
        let item = s.enqueue(text: "bom dia", at: t0)
        let blocked = s.next(at: t0, overlayReady: true)
        #expect(blocked.dispatch == nil)

        s.setGloss(id: item.id, gloss: "BOM DIA")
        let withoutOverlay = s.next(at: t0, overlayReady: false)
        #expect(withoutOverlay.dispatch == nil)

        let step = s.next(at: t0.addingTimeInterval(1), overlayReady: true)
        #expect(step.dispatch?.gloss == "BOM DIA")
        #expect(step.dispatch?.speed == 1)
        #expect(s.queue.isEmpty)
    }

    @Test func keepsSpeechOrder() {
        var s = scheduler()
        let first = s.enqueue(text: "um", at: t0)
        let second = s.enqueue(text: "dois", at: t0)
        s.setGloss(id: second.id, gloss: "DOIS")
        let blocked = s.next(at: t0, overlayReady: true)
        #expect(blocked.dispatch == nil)

        s.setGloss(id: first.id, gloss: "UM")
        let step = s.next(at: t0, overlayReady: true)
        #expect(step.dispatch?.itemIDs == [first.id, second.id])
        #expect(step.dispatch?.gloss == "UM DOIS")
    }

    @Test func mergesReadyPhrasesIntoOneDispatch() {
        var s = scheduler()
        for (text, gloss) in [("oi", "OI [PONTO]"), ("tudo bem", "TUDO BEM [INTERROGAÇÃO]"), ("sim", "SIM [PONTO]")] {
            let item = s.enqueue(text: text, at: t0)
            s.setGloss(id: item.id, gloss: gloss)
        }
        let step = s.next(at: t0, overlayReady: true)
        #expect(step.dispatch?.itemIDs == [1, 2, 3])
        #expect(step.dispatch?.gloss == "OI TUDO BEM [INTERROGAÇÃO] SIM")
        #expect(step.dispatch?.id == 1)
        #expect(s.playing?.itemIDs == [1, 2, 3])
    }

    @Test func mergeStopsAtFirstUntranslatedItem() {
        var s = scheduler()
        let a = s.enqueue(text: "um", at: t0)
        _ = s.enqueue(text: "dois", at: t0)
        let c = s.enqueue(text: "três", at: t0)
        s.setGloss(id: a.id, gloss: "UM")
        s.setGloss(id: c.id, gloss: "TRÊS")
        let step = s.next(at: t0, overlayReady: true)
        #expect(step.dispatch?.itemIDs == [a.id])
        #expect(s.queue.count == 2)
    }

    @Test func mergeRespectsMaxBatchSeconds() {
        var s = scheduler(maxBatch: 6)
        for _ in 0..<3 {
            let item = s.enqueue(text: "frase", at: t0)
            s.setGloss(id: item.id, gloss: "A B C")  // 3 s cada (1 s por sinal) + 2 s fixos
        }
        let step = s.next(at: t0, overlayReady: true)
        #expect(step.dispatch?.itemIDs.count == 1)
    }

    @Test func noMergeWhenDisabled() {
        var s = scheduler(merge: false)
        for _ in 0..<2 {
            let item = s.enqueue(text: "frase", at: t0)
            s.setGloss(id: item.id, gloss: "A")
        }
        #expect(s.next(at: t0, overlayReady: true).dispatch?.itemIDs.count == 1)
    }

    @Test func joinsWithoutRepeatingBoundarySign() {
        var s = scheduler()
        for gloss in ["JESUS LÁ NÃO", "NÃO REINAR"] {
            let item = s.enqueue(text: "x y", at: t0)
            s.setGloss(id: item.id, gloss: gloss)
        }
        #expect(s.next(at: t0, overlayReady: true).dispatch?.gloss == "JESUS LÁ NÃO REINAR")
    }

    @Test func skipsItemsThatBecomeEmpty() {
        var s = scheduler()
        let empty = s.enqueue(text: "...", at: t0)
        s.setGloss(id: empty.id, gloss: "[PONTO]")
        let real = s.enqueue(text: "oi", at: t0.addingTimeInterval(30))
        s.setGloss(id: real.id, gloss: "OI")
        let step = s.next(at: t0.addingTimeInterval(31), overlayReady: true)
        #expect(step.dispatch?.itemIDs == [real.id])
        #expect(step.dropped.map(\.reason).contains(.empty) || step.dropped.map(\.reason).contains(.stale))
    }

    @Test func doesNotDispatchWhilePlaying() {
        var s = scheduler(merge: false)
        let a = s.enqueue(text: "um", at: t0)
        let b = s.enqueue(text: "dois", at: t0)
        s.setGloss(id: a.id, gloss: "UM")
        s.setGloss(id: b.id, gloss: "DOIS")

        let first = s.next(at: t0, overlayReady: true)
        #expect(first.dispatch?.id == a.id)
        let blocked = s.next(at: t0, overlayReady: true)
        #expect(blocked.dispatch == nil)

        let wrong = s.markEnded(id: 999)
        let right = s.markEnded(id: a.id)
        #expect(wrong == nil)
        #expect(right?.itemIDs == [a.id])
        let second = s.next(at: t0, overlayReady: true)
        #expect(second.dispatch?.id == b.id)
    }

    @Test func speedsUpWithBacklog() {
        var s = scheduler(merge: false)
        for _ in 0..<5 {
            let item = s.enqueue(text: "frase", at: t0)
            s.setGloss(id: item.id, gloss: "A B C D E")  // 5 s de sinais cada
        }
        // Último espera 4 × 5 s = 20 s → velocidade máxima.
        #expect(s.next(at: t0, overlayReady: true).dispatch?.speed == 2)
    }

    @Test func singleLongSentenceKeepsNormalSpeed() {
        var s = scheduler()
        let item = s.enqueue(text: "bom dia pessoal hoje vamos falar sobre tecnologia na live agora", at: t0)
        s.setGloss(id: item.id, gloss: "BOM_DIA PESSOAL HOJE FALAR SOBRE TECNOLOGIA LIVE AGORA")
        #expect(s.next(at: t0.addingTimeInterval(1), overlayReady: true).dispatch?.speed == 1)
    }

    @Test func compactsGlossWhenBehind() {
        var s = scheduler(merge: false)
        let old = s.enqueue(text: "então aqui discernirmos", at: t0)
        s.setGloss(id: old.id, tokens: ["ENTÃO", "AQUI", "DISCERNIRMO"], availability: ["DISCERNIRMO": false])
        let newest = s.enqueue(text: "x", at: t0.addingTimeInterval(11))
        s.setGloss(id: newest.id, gloss: "X")

        // Atraso de 11 s ≥ (5 + 15) / 2 → pula palavras sem sinal e muletas.
        let step = s.next(at: t0.addingTimeInterval(11), overlayReady: true)
        #expect(step.dispatch?.gloss == "AQUI")
        #expect(step.dispatch?.parts.first?.optimization.removed == ["ENTÃO", "DISCERNIRMO"])
    }

    @Test func dropsRepeatedRefrainWhenBehind() {
        var s = scheduler(merge: false)
        let first = s.enqueue(text: "Jesus não está lá", at: t0)
        s.setGloss(id: first.id, gloss: "JESUS LÁ NÃO [PONTO]")
        _ = s.next(at: t0, overlayReady: true)
        s.markEnded(id: first.id)

        let repeated = s.enqueue(text: "Jesus não está lá", at: t0.addingTimeInterval(1))
        s.setGloss(id: repeated.id, gloss: "JESUS LÁ NÃO [PONTO]")
        let other = s.enqueue(text: "o dinheiro", at: t0.addingTimeInterval(2))
        s.setGloss(id: other.id, gloss: "DINHEIRO MUNDO GANHAR")

        let step = s.next(at: t0.addingTimeInterval(7), overlayReady: true)
        #expect(step.dropped.first?.reason == .repeated)
        #expect(step.dropped.first?.item.id == repeated.id)
        #expect(step.dispatch?.itemIDs == [other.id])
    }

    @Test func keepsRepeatWhenNotBehind() {
        var s = scheduler(merge: false)
        let first = s.enqueue(text: "amém", at: t0)
        s.setGloss(id: first.id, gloss: "AMÉM")
        _ = s.next(at: t0, overlayReady: true)
        s.markEnded(id: first.id)

        let again = s.enqueue(text: "amém", at: t0.addingTimeInterval(1))
        s.setGloss(id: again.id, gloss: "AMÉM")
        #expect(s.next(at: t0.addingTimeInterval(1.5), overlayReady: true).dispatch?.id == again.id)
    }

    @Test func dropsStaleButKeepsNewest() {
        var s = scheduler(merge: false, repeats: false)
        for offset in [0.0, 1, 2] {
            let item = s.enqueue(text: "frase", at: t0.addingTimeInterval(offset))
            s.setGloss(id: item.id, gloss: "FRASE")
        }
        let step = s.next(at: t0.addingTimeInterval(20), overlayReady: true)
        #expect(step.dispatch?.id == 3)
        #expect(step.dropped.map(\.reason) == [.stale, .stale])
        #expect(s.droppedCount == 2)
    }

    @Test func dropsEvenNewestWhenVeryOld() {
        var s = scheduler()
        let item = s.enqueue(text: "frase", at: t0)
        s.setGloss(id: item.id, gloss: "FRASE")
        let step = s.next(at: t0.addingTimeInterval(31), overlayReady: true)
        #expect(step.dispatch == nil)
        #expect(s.droppedCount == 1)
    }

    @Test func expiresWhenOverlayIsSilent() {
        var s = scheduler()
        let item = s.enqueue(text: "oi", at: t0)
        s.setGloss(id: item.id, gloss: "OI")
        _ = s.next(at: t0, overlayReady: true)

        let early = s.expireIfNeeded(at: t0.addingTimeInterval(5))
        let late = s.expireIfNeeded(at: t0.addingTimeInterval(16))
        #expect(early == nil)
        #expect(late?.itemIDs == [item.id])
        #expect(s.playing == nil)
    }

    @Test func clearReturnsDroppedItems() {
        var s = scheduler()
        s.enqueue(text: "a", at: t0)
        s.enqueue(text: "b", at: t0)
        #expect(s.clear().count == 2)
        #expect(s.queue.isEmpty)
        #expect(s.droppedCount == 2)
    }
}
