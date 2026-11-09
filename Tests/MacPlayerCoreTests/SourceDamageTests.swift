import Foundation
import Testing
@testable import MacPlayerCore

struct SourceDamageTests {
    @Test func clockShowsMinutesAndHours() {
        #expect(SourceDamage.clock(0) == "0:00")
        #expect(SourceDamage.clock(2200.267) == "36:40")
        #expect(SourceDamage.clock(3723) == "1:02:03")
        #expect(SourceDamage.clock(-5) == "0:00")
    }

    @Test func messageNamesWhereTheDataStopsAndCanBeReadBack() {
        let m = SourceDamage.message(readable: 2200.267, declared: 2208.8)
        #expect(m.contains("36:40") && m.contains("36:48") && m.contains("incomplete download"))
        let p = SourceDamage.parse(m)
        #expect(p?.readable == "36:40" && p?.declared == "36:48")
        #expect(SourceDamage.parse("Export failed: something else") == nil)
    }

    @Test func aFailedExportIsNotLabelledFailedTwice() {
        let once = SaveError.produceFailed("Export failed: no room").description
        #expect(once == "Export failed: no room. The original is untouched.")
        let plain = SaveError.produceFailed("no room").description
        #expect(plain == "Export failed: no room. The original is untouched.")
        let withStop = SaveError.produceFailed("it broke.").description
        #expect(withStop == "Export failed: it broke. The original is untouched.")
    }
}
