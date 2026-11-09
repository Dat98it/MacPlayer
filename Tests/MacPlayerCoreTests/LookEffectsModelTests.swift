import Foundation
import Testing
@testable import MacPlayerCore

struct LookEffectsModelTests {
    @Test func aLookSavedBeforeEffectsExistedStillOpens() throws {
        var look = VideoLook(); look.rotation = 90; look.effects.filter = .noir; look.effects.vignette = 0.4
        let data = try JSONEncoder().encode(look)
        #expect(try JSONDecoder().decode(VideoLook.self, from: data) == look)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "effects")
        let old = try JSONDecoder().decode(VideoLook.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.rotation == 90 && old.effects.isNeutral)
    }

    @Test func effectsCountAsAPictureChangeSoAFastCutIsNotUsed() {
        var look = VideoLook()
        #expect(look.isNeutral)
        look.effects.blurBackground = true
        #expect(look.changesPicture && !look.isNeutral)
        look = VideoLook(); look.effects.filter = .vivid
        #expect(look.changesPicture)
        look = VideoLook(); look.effects.filter = .none; look.effects.filterAmount = 0.3
        #expect(!look.changesPicture, "an amount with no filter changes nothing")
    }

    @Test func valuesAreKeptInRange() {
        var e = LookEffects(); e.filterAmount = 4; e.blur = -2; e.vignette = 9; e.sharpen = 0.5; e.blurBackgroundAmount = 2
        let c = e.clamped()
        #expect(c.filterAmount == 1 && c.blur == 0 && c.vignette == 1 && c.sharpen == 0.5 && c.blurBackgroundAmount == 1)
    }

    @Test func aLayerWithoutChromaKeyOpensFromAnOlderFile() throws {
        var t = OverlayTransform(); t.chromaKey = ChromaKey(colorHex: "#00AA00", tolerance: 0.4, softness: 0.1)
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(OverlayTransform.self, from: data).chromaKey?.colorHex == "#00AA00")
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "chromaKey")
        #expect(try JSONDecoder().decode(OverlayTransform.self, from: JSONSerialization.data(withJSONObject: obj)).chromaKey == nil)
    }
}
