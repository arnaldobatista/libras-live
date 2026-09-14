import Testing
@testable import OverlayServer

@Suite struct SignCacheNameTests {
    @Test(arguments: ["BOM", "BOA_NOITE", "PESSOAL&PARTICULAR", "[PONTO]", "OLÁ", "TRANSMISSÃO&DIFUSÃO", "2026"])
    func acceptsGlossTokens(_ name: String) {
        #expect(SignCache.isValidName(name))
    }

    @Test(arguments: ["", "..", "../etc", "a/b", "BOM?x=1", String(repeating: "A", count: 121)])
    func rejectsUnsafeNames(_ name: String) {
        #expect(!SignCache.isValidName(name))
    }
}
