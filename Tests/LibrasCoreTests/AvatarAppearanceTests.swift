import CoreGraphics
import Foundation
import Testing
@testable import LibrasCore

@Suite struct AvatarAppearanceTests {
    @Test func buildsPlayerJSONWithPlayerKeys() throws {
        var appearance = AvatarAppearance()
        appearance.shirt = "#f1c40f"
        appearance.logoPosition = .centerAndChest
        let json = appearance.personalizationJSON(logoURL: "http://127.0.0.1:8765/appearance/logo.png?v=2&vlibras.gov.br")
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(Set(object.keys) == ["cabelo", "calca", "camisa", "corpo", "iris", "olhos", "sombrancelhas", "logo", "pos"])
        #expect(object["camisa"] == "#F1C40F")
        #expect(object["pos"] == "centerAndChest")
        #expect(object["logo"]?.contains("vlibras.gov.br") == true)
    }

    @Test func invalidColorFallsBackToDefault() throws {
        var appearance = AvatarAppearance()
        appearance.pants = "azul"
        let json = appearance.personalizationJSON(logoURL: "")
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object["calca"] == AvatarAppearance.vlibrasColors.pants)
    }

    @Test func normalizesHex() {
        #expect(AvatarAppearance.normalizedHex("#abc") == "#AABBCC")
        #expect(AvatarAppearance.normalizedHex("1b35ff") == "#1B35FF")
        #expect(AvatarAppearance.normalizedHex(" #0D0D0F ") == "#0D0D0F")
        #expect(AvatarAppearance.normalizedHex("#12345") == nil)
        #expect(AvatarAppearance.normalizedHex("#GGGGGG") == nil)
    }

    @Test func reloadOnlyWhenJSONCannotRestore() {
        var custom = AvatarAppearance()
        custom.enabled = true
        custom.logoMode = .custom

        var disabled = custom
        disabled.enabled = false
        #expect(disabled.needsReload(comparedTo: custom))

        var backToVLibras = custom
        backToVLibras.logoMode = .vlibras
        #expect(backToVLibras.needsReload(comparedTo: custom))

        var newShirt = custom
        newShirt.shirt = "#000000"
        #expect(!newShirt.needsReload(comparedTo: custom))

        var enabling = AvatarAppearance()
        enabling.enabled = true
        #expect(!enabling.needsReload(comparedTo: AvatarAppearance()))
    }

    @Test func decodesPartialPreferences() throws {
        let decoded = try JSONDecoder().decode(AvatarAppearance.self, from: Data(##"{"enabled":true,"shirt":"#000000"}"##.utf8))
        #expect(decoded.enabled)
        #expect(decoded.shirt == "#000000")
        #expect(decoded.pants == AvatarAppearance.vlibrasColors.pants)
        #expect(decoded.logoMode == .vlibras)
    }
}

@Suite struct AvatarAppearancePatchTests {
    @Test func appliesOnlyValidFields() throws {
        let patch = try JSONDecoder().decode(AvatarAppearancePatch.self, from: Data(##"{"shirt":"#ff0000","pants":"verde","logoPosition":"center","logoScale":9}"##.utf8))
        let result = patch.applied(to: AvatarAppearance())
        #expect(result.shirt == "#FF0000")
        #expect(result.pants == AvatarAppearance.vlibrasColors.pants)
        #expect(result.logoPosition == .center)
        #expect(result.logoScale == 1)
        #expect(result.enabled == false)
    }
}

@Suite struct LogoLayoutTests {
    @Test func fitsInsideSafeArea() {
        let frame = LogoLayout.frame(for: CGSize(width: 1000, height: 500), scale: 1, offsetX: 0, offsetY: 0)
        #expect(frame.width == 350)
        #expect(frame.height == 175)
        #expect(frame.minX == 75)
        #expect(frame.midY == 250)
    }

    @Test func scaleAndOffsetStayInsideSafeArea() {
        let frame = LogoLayout.frame(for: CGSize(width: 500, height: 500), scale: 0.5, offsetX: 1, offsetY: -1)
        #expect(frame.width == 175)
        #expect(frame.maxX == 425)
        #expect(frame.minY == 75)
    }

    @Test func clampsOutOfRangeValues() {
        let frame = LogoLayout.frame(for: CGSize(width: 100, height: 100), scale: 5, offsetX: 3, offsetY: 3)
        #expect(frame.width == 350)
        #expect(frame.minX == 75)
    }
}
