import Foundation
import Testing
@testable import LibrasCore

@Suite struct VoiceActivityDetectorTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    /// Alimenta níveis a 20 Hz a partir de `start`; devolve o instante seguinte.
    @discardableResult
    func feed(_ vad: inout VoiceActivityDetector, db: Float, seconds: Double, from start: Date) -> Date {
        var now = start
        for _ in 0..<Int(seconds * 20) {
            vad.observe(levelDB: db, at: now)
            now = now.addingTimeInterval(0.05)
        }
        return now
    }

    @Test func learnsNoiseFloorAndDetectsSpeech() {
        var vad = VoiceActivityDetector()
        var now = feed(&vad, db: -48, seconds: 3, from: t0)
        #expect(abs(vad.noiseFloorDB - -48) < 2)
        #expect(vad.silenceDuration(at: now) > 2)

        now = feed(&vad, db: -25, seconds: 1, from: now)
        #expect(vad.silenceDuration(at: now) == 0)
        #expect(vad.lastSpeechAt != nil)
    }

    @Test func measuresSilenceAfterSpeech() {
        var vad = VoiceActivityDetector()
        var now = feed(&vad, db: -55, seconds: 2, from: t0)
        now = feed(&vad, db: -20, seconds: 2, from: now)
        now = feed(&vad, db: -55, seconds: 0.7, from: now)
        #expect(abs(vad.silenceDuration(at: now) - 0.7) < 0.1)
    }

    @Test func floorFollowsRisingNoiseSlowly() {
        var vad = VoiceActivityDetector()
        var now = feed(&vad, db: -60, seconds: 2, from: t0)
        // Ruído sobe para -40 (ventilador, plateia): depois de alguns segundos vira piso.
        now = feed(&vad, db: -40, seconds: 8, from: now)
        #expect(vad.noiseFloorDB > -42)
        #expect(vad.silenceDuration(at: now) > 0)
    }

    @Test func briefDipsInsideSpeechDoNotCountAsLongSilence() {
        var vad = VoiceActivityDetector()
        var now = feed(&vad, db: -55, seconds: 2, from: t0)
        for _ in 0..<5 {
            now = feed(&vad, db: -22, seconds: 0.4, from: now)
            now = feed(&vad, db: -52, seconds: 0.15, from: now)
        }
        #expect(vad.silenceDuration(at: now) < 0.2)
    }
}

@Suite struct PauseCommitRuleTests {
    let rule = PauseCommitRule(silenceSeconds: 0.6, stableSeconds: 1.2, stalledSeconds: 2.5)

    @Test func recognizerCadenceAloneIsNotAPause() {
        // Caso da live: 0,9 s sem atualização, mas a pessoa continua falando.
        #expect(rule.decide(silence: 0, unchangedFor: 0.9) == .wait)
    }

    @Test func silenceNeedsStableHypothesis() {
        #expect(rule.decide(silence: 0.8, unchangedFor: 0.5) == .wait)
        #expect(rule.decide(silence: 0.8, unchangedFor: 1.3) == .silence)
    }

    @Test func stalledHypothesisCommitsWithoutSilence() {
        #expect(rule.decide(silence: 0, unchangedFor: 2.6) == .stalled)
    }

    @Test func silenceDetectionCanBeDisabled() {
        let noSilence = PauseCommitRule(silenceSeconds: 0, stableSeconds: 1.2, stalledSeconds: 2.5)
        #expect(noSilence.decide(silence: 5, unchangedFor: 1.5) == .wait)
    }
}
