import Foundation

/// The message for a video file whose data stops being readable partway (an incomplete download, a bad disk): what the
/// person is told, kept in one place so the app can recognise it and show it in their language.
public enum SourceDamage {
    /// "36:40" or "1:02:03".
    public static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func message(readable: Double, declared: Double) -> String {
        "The video file is damaged: its picture or sound cannot be decoded after \(clock(readable)) (the file says it is \(clock(declared)) long). "
        + "It may be an incomplete download. A fast cut copies the data as it is; an exact export has to decode everything, "
        + "so end it at \(clock(readable)) to export the part that can be read."
    }

    /// The two times inside a message made by `message`, or nil when the text is something else.
    public static func parse(_ text: String) -> (readable: String, declared: String)? {
        guard let r = text.range(of: #"after (\S+) \(the file says it is (\S+) long\)"#, options: .regularExpression) else { return nil }
        let parts = text[r].split(separator: " ")
        // "after", "36:40", "(the", "file", "says", "it", "is", "36:48", "long)"
        guard parts.count == 9 else { return nil }
        return (String(parts[1]), String(parts[7]))
    }
}
