import Foundation
import Testing
@testable import MacPlayerCore

struct ItemDetailsTests {
    @Test func codecsGetTheirFamiliarNames() {
        #expect(ItemDetails.codecName("avc1") == "H.264" && ItemDetails.codecName("avc3") == "H.264")
        #expect(ItemDetails.codecName("hvc1") == "HEVC (H.265)" && ItemDetails.codecName("hev1") == "HEVC (H.265)")
        #expect(ItemDetails.codecName("dvh1") == "HEVC (Dolby Vision)")
        #expect(ItemDetails.codecName("apch") == "ProRes" && ItemDetails.codecName("av01") == "AV1")
        #expect(ItemDetails.codecName("aac") == "AAC" && ItemDetails.codecName("ac-3") == "AC-3" && ItemDetails.codecName("lpcm") == "PCM")
    }

    @Test func anUnknownCodecIsShownAsItIsWithoutPadding() {
        #expect(ItemDetails.codecName("xyz ") == "XYZ")
        #expect(ItemDetails.codecName("") == "")
    }

    @Test func frameRatesHaveNoNeedlessZeros() {
        #expect(ItemDetails.frameRateLabel(30) == "30 fps")
        #expect(ItemDetails.frameRateLabel(29.97) == "29.97 fps")
        #expect(ItemDetails.frameRateLabel(59.94005994) == "59.94 fps")
        #expect(ItemDetails.frameRateLabel(23.976) == "23.98 fps")
        #expect(ItemDetails.frameRateLabel(25.5) == "25.5 fps")
    }

    @Test func sizesAndRatesReadNaturally() {
        #expect(ItemDetails.resolutionLabel(width: 1920, height: 1080) == "1920×1080")
        #expect(ItemDetails.bitrateLabel(4_989_348) == "5.0 Mb/s")
        #expect(ItemDetails.bitrateLabel(320_000) == "320 kb/s")
    }
}
