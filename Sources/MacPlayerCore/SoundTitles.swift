import Foundation

/// The words of a song in a project made from it (0.16.2): its title and artist as ordinary texts under the cover picture, so they can be
/// changed, moved, restyled or deleted like any text. (0.16.0/0.16.1 drew them into the cover video, where they could not be edited.)
public enum SoundTitles {
    /// Where the texts sit, from the top of the picture: under the cover tile (which fills 15%…65% of the height).
    public static let titleY = 0.775
    public static let artistY = 0.885

    /// The texts for a song shown from `start` to `end` on the timeline. The artist line also names the album when the song has one.
    /// An empty title gives no title text; no artist gives no second text.
    public static func overlays(title: String, artist: String?, album: String?, start: MediaTime, end: MediaTime) -> [TextOverlay] {
        var out: [TextOverlay] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            var o = TextOverlay(text: t, start: start, end: end, fontName: "HelveticaNeue-Bold", sizeFraction: 0.055, colorHex: "#FFFFFF",
                                alignment: .center, x: 0.5, y: titleY, fade: 0.3)
            var f = TextFlair(); f.shadow = true; f.shadowHex = "#000000"; f.outlineWidth = 0
            o.flair = f
            out.append(o)
        }
        let a = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", b = album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !a.isEmpty {
            var o = TextOverlay(text: b.isEmpty ? a : a + " · " + b, start: start, end: end, fontName: "HelveticaNeue-Medium", sizeFraction: 0.036,
                                colorHex: "#E6E6E6", alignment: .center, x: 0.5, y: artistY, fade: 0.3)
            var f = TextFlair(); f.shadow = true; f.shadowHex = "#000000"; f.outlineWidth = 0
            o.flair = f
            out.append(o)
        }
        return out
    }
}
