import Testing
@testable import OverlayServer

@Suite struct OriginPolicyTests {
    @Test(arguments: ["127.0.0.1:8765", "localhost:8765", "LOCALHOST:8765", "[::1]:8765"])
    func acceptsLocalHosts(_ host: String) {
        #expect(OriginPolicy.isLocalHost(host, port: 8765))
    }

    @Test(arguments: ["evil.com:8765", "127.0.0.1:9999", "127.0.0.1", "192.168.0.10:8765"])
    func rejectsOtherHosts(_ host: String) {
        #expect(!OriginPolicy.isLocalHost(host, port: 8765))
    }

    @Test func allowsMissingOriginAndSameOrigin() {
        #expect(OriginPolicy.isAllowedOrigin(nil, port: 8765))
        #expect(OriginPolicy.isAllowedOrigin("http://127.0.0.1:8765", port: 8765))
        #expect(OriginPolicy.isAllowedOrigin("http://localhost:8765", port: 8765))
    }

    @Test func rejectsForeignOrigins() {
        #expect(!OriginPolicy.isAllowedOrigin("https://evil.com", port: 8765))
        #expect(!OriginPolicy.isAllowedOrigin("http://127.0.0.1:3000", port: 8765))
        #expect(!OriginPolicy.isAllowedOrigin("null", port: 8765))
    }
}
