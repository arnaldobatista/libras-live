import Foundation
import Testing
@testable import LibrasCore

@Suite struct SessionLogFormatterTests {
    let jsonl = """
    {"ev":"session.start","t":"2026-09-14T09:35:00.000Z","device":"Soundcraft Ui24","channels":[5],"settings":"vel 2.0–3.0×"}
    {"ev":"listen.start","t":"2026-09-14T09:35:01.000Z"}
    {"ev":"commit","t":"2026-09-14T09:35:04.000Z","text":"Jesus não está lá.","source":"estável"}
    {"ev":"enqueue","t":"2026-09-14T09:35:04.010Z","id":1,"text":"Jesus não está lá."}
    {"ev":"gloss","t":"2026-09-14T09:35:04.120Z","id":1,"gloss":"JESUS LÁ NÃO [PONTO]","source":"remote","ms":110}
    {"ev":"optimize","t":"2026-09-14T09:35:04.200Z","id":1,"gloss":"JESUS LÁ NÃO","removed":["[PONTO]"],"replaced":[],"spelled":[]}
    {"ev":"dispatch","t":"2026-09-14T09:35:04.200Z","id":1,"ids":[1],"gloss":"JESUS LÁ NÃO","speed":2.0,"lag":0.2,"queued":0}
    {"ev":"ended","t":"2026-09-14T09:35:09.200Z","id":1,"reason":"done","duration":5.0}
    {"ev":"drop","t":"2026-09-14T09:35:20.000Z","id":2,"text":"Amém","reason":"atrasada","age":16.0}
    {"ev":"sign.missing","t":"2026-09-14T09:35:21.000Z","name":"DISCERNIRMO"}
    {"ev":"listen.stop","t":"2026-09-14T09:35:31.000Z"}
    """

    @Test func summarizesSession() {
        let summary = SessionLogFormatter.summarize(SessionLogFormatter.parse(jsonl))
        #expect(summary.commits == 1)
        #expect(summary.dispatched == 1)
        #expect(summary.dropped == 1)
        #expect(summary.dropRate == 0.5)
        #expect(summary.speeds == [2.0])
        #expect(summary.missingSigns == ["DISCERNIRMO": 1])
        #expect(summary.removedTokens == ["[PONTO]": 1])
        #expect(abs(summary.playingSeconds - 5) < 0.01)
        // Ouvindo de 01 a 31 (30 s), sinalizando 5 s: parado 3,2 s antes + 21,8 s depois.
        #expect(abs(summary.idleSeconds - 25.0) < 0.01)
        #expect(summary.commitSources == ["estável": 1])
        #expect(summary.dispatchSizes == [1])
        #expect(abs((summary.queueWaits.first ?? 0) - 0.19) < 0.01)
    }

    @Test func formatsReadableTimeline() {
        let text = SessionLogFormatter.format(jsonl)
        #expect(text.contains("Sinalizados: 1   Descartados: 1 (50%)"))
        #expect(text.contains("FALA      Jesus não está lá.  [estável]"))
        #expect(text.contains("TOCA"))
        #expect(text.contains("DESCARTE"))
        #expect(text.contains("Sinais inexistentes: DISCERNIRMO×1"))
    }

    @Test func ignoresBrokenLines() {
        #expect(SessionLogFormatter.parse("lixo\n{\"ev\":\"clear\",\"t\":\"2026-09-14T09:35:00.000Z\"}\n").count == 1)
    }
}

@Suite struct PlaybackSimulatorTests {
    let phrases = [
        PlaybackSimulator.Phrase(time: 0, text: "um", tokens: ["A", "B"]),
        PlaybackSimulator.Phrase(time: 1, text: "dois", tokens: ["C", "D"]),
        PlaybackSimulator.Phrase(time: 2, text: "três", tokens: ["E", "F"]),
    ]

    @Test func mergingNeedsFewerDispatches() {
        let costs = SigningCosts(overheadPerPlay: 2, secondsPerSign: 2, secondsPerLetter: 1, secondsPerMarker: 1)
        let separate = PlaybackSimulator(policy: BacklogPolicy(mergePhrases: false), glossOptions: .init(), costs: costs)
            .run(phrases, availability: [:])
        let merged = PlaybackSimulator(policy: BacklogPolicy(mergePhrases: true), glossOptions: .init(), costs: costs)
            .run(phrases, availability: [:])
        #expect(separate.dispatches == 3)
        #expect(merged.dispatches == 2)
        #expect(merged.sessionSeconds < separate.sessionSeconds)
    }

    @Test func parsesTSVWithSameSecondOffsets() {
        let parsed = PlaybackSimulator.parseTSV("# comentário\n09:36:00\ta tua palavra.\tTUA PALAVRA\n09:36:00\tamém\tAMÉM\n")
        #expect(parsed.count == 2)
        #expect(parsed[1].time - parsed[0].time == 0.5)
        #expect(parsed[0].tokens == ["TUA", "PALAVRA"])
    }
}
