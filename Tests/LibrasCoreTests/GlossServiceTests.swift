import Foundation
import Testing
@testable import LibrasCore

private actor CountingTranslator: GlossTranslating {
    var calls = 0
    var shouldFail = false

    func setFailing(_ value: Bool) { shouldFail = value }

    func gloss(for text: String) async throws -> String {
        calls += 1
        if shouldFail { throw GlossError.badStatus(503) }
        return "G(\(text))"
    }
}

private actor FlakyTranslator: GlossTranslating {
    var calls = 0
    func gloss(for text: String) async throws -> String {
        calls += 1
        if calls == 1 { throw GlossError.badStatus(504) }
        return "OK"
    }
}

@Suite struct GlossServiceTests {
    @Test func retriesBeforeFallback() async {
        let translator = FlakyTranslator()
        let service = GlossService(translator: translator, attempts: 2)
        let result = await service.translate("teste")
        #expect(result.source == .remote)
        #expect(await translator.calls == 2)
    }

    @Test func cachesNormalizedText() async {
        let translator = CountingTranslator()
        let service = GlossService(translator: translator)

        let first = await service.translate("Bom  dia")
        let second = await service.translate("bom dia")

        #expect(first.source == .remote)
        #expect(second.source == .cache)
        #expect(second.gloss == "G(Bom  dia)")
        #expect(await translator.calls == 1)
    }

    @Test func fallsBackWhenTranslatorFails() async {
        let translator = CountingTranslator()
        await translator.setFailing(true)
        let service = GlossService(translator: translator)

        let result = await service.translate("Olá, mundo!")
        #expect(result.source == .fallback)
        #expect(result.gloss == "OLÁ MUNDO")
        #expect(result.error != nil)
    }

    @Test func evictsOldestEntries() async {
        let service = GlossService(translator: CountingTranslator(), capacity: 10)
        for i in 0..<11 { _ = await service.translate("frase \(i)") }
        #expect(await service.count == 10)
        #expect(await service.translate("frase 10").source == .cache)
        #expect(await service.translate("frase 0").source == .remote)
    }

    @Test func persistsToDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = GlossService(translator: CountingTranslator(), cacheURL: url)
        _ = await writer.translate("teste")
        await writer.save()

        let translator = CountingTranslator()
        let reader = GlossService(translator: translator, cacheURL: url)
        await reader.load()
        #expect(await reader.translate("teste").source == .cache)
        #expect(await translator.calls == 0)
    }
}

@Suite struct OverlayProtocolTests {
    @Test func encodesGloss() throws {
        let json = OverlayOutbound.gloss(id: 7, gloss: "BOM DIA", text: "Bom dia", speed: 1.5).json()
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "gloss")
        #expect(object["id"] as? Int == 7)
        #expect(object["gloss"] as? String == "BOM DIA")
        #expect(object["speed"] as? Double == 1.5)
    }

    @Test func omitsNilConfigFields() {
        let json = OverlayOutbound.config(OverlayConfig(avatar: "hosana")).json()
        #expect(json.contains("\"avatar\":\"hosana\""))
        #expect(!json.contains("subtitles"))
    }

    @Test func decodesInbound() {
        let message = OverlayInbound.decode(#"{"type":"ended","id":3,"reason":"done"}"#)
        #expect(message?.type == .ended)
        #expect(message?.id == 3)
        #expect(OverlayInbound.decode(#"{"type":"unknown"}"#) == nil)
        #expect(OverlayInbound.decode("lixo") == nil)
    }
}
