import Foundation

public struct SubtitleCue: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: MediaTime
    public var end: MediaTime
    public var text: String

    public init(id: UUID = UUID(), start: MediaTime, end: MediaTime, text: String) {
        self.id = id; self.start = start; self.end = end; self.text = text
    }

    /// Text without SRT/VTT tags (`<i>`, `{\an8}`) for drawing and searching.
    public var plainText: String {
        var s = text
        while let a = s.range(of: "<"), let b = s[a.lowerBound...].range(of: ">") { s.removeSubrange(a.lowerBound..<b.upperBound) }
        while let a = s.range(of: "{\\"), let b = s[a.lowerBound...].range(of: "}") { s.removeSubrange(a.lowerBound..<b.upperBound) }
        return s
    }
}

public struct SubtitleStyle: Codable, Equatable, Sendable {
    public var fontName = "Helvetica-Bold"
    /// Fraction of the picture height.
    public var sizeFraction = 0.05
    public var colorHex = "#FFFFFF"
    public var outlineHex: String? = "#000000"
    public var backgroundHex: String? = nil
    public var alignment: TextAlignmentChoice = .center
    /// Distance of the text's bottom edge from the bottom of the picture, as a fraction of its height.
    public var bottomMargin = 0.07
    public init() {}

    /// Vertical 9:16 video: larger text, and kept clear of the area that apps cover with their own buttons.
    public static var portrait: SubtitleStyle {
        var s = SubtitleStyle(); s.sizeFraction = 0.04; s.bottomMargin = 0.2; return s
    }
}

public struct SubtitleDocument: Codable, Equatable, Sendable {
    public var language: String?
    public var cues: [SubtitleCue] = []
    public var style = SubtitleStyle()
    /// Draw the subtitles into the picture on export (needs re-encoding).
    public var burnIn = false
    /// Delay applied to every cue when exporting, in seconds (the "sync" control).
    public var syncOffset: Double = 0
    public init() {}
}

public struct SubtitleIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case emptyText, endsBeforeStart, overlapsPrevious, startsAfterVideoEnds, endsAfterVideoEnds }
    public var cueID: UUID
    public var kind: Kind
}

public enum SubtitleError: Error, Equatable, CustomStringConvertible {
    case notSubtitleText
    case noCues
    public var description: String {
        switch self {
        case .notSubtitleText: return "This file is not a readable subtitle file."
        case .noCues: return "No subtitle cues were found in the file."
        }
    }
}

public struct SubtitleParseResult: Equatable, Sendable {
    public var cues: [SubtitleCue]
    /// Human-readable notes about blocks that were skipped.
    public var warnings: [String]
    /// Name of the text encoding that was used, so the user can see it and override it.
    public var encoding: String
}

public enum SubtitleCodec {
    // MARK: Text encoding (Vietnamese diacritics must survive)

    public static let vietnameseWindows: String.Encoding = {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsVietnamese.rawValue)))
    }()

    public static let encodingChoices: [(name: String, encoding: String.Encoding)] = [
        ("UTF-8", .utf8), ("UTF-16", .utf16), ("Windows-1258 (Vietnamese)", vietnameseWindows),
        ("Windows-1252", .windowsCP1252), ("ISO Latin 1", .isoLatin1),
    ]

    /// Decodes subtitle bytes: BOM first, then strict UTF-8, then Windows-1258 (the common legacy Vietnamese encoding).
    public static func decode(_ data: Data, forcing forced: String.Encoding? = nil) -> (text: String, encoding: String)? {
        // A forced encoding is the user's choice: if it cannot read the bytes, say so rather than guessing another.
        if let f = forced {
            guard let s = String(data: data, encoding: f) else { return nil }
            return (strip(s), name(of: f))
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return (s, "UTF-8") }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return (strip(s), "UTF-16") }
        if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8") }
        if let s = String(data: data, encoding: vietnameseWindows) { return (s, "Windows-1258 (Vietnamese)") }
        if let s = String(data: data, encoding: .isoLatin1) { return (s, "ISO Latin 1") }
        return nil
    }

    private static func strip(_ s: String) -> String { s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
    private static func name(of e: String.Encoding) -> String { encodingChoices.first { $0.encoding == e }?.name ?? "custom" }

    // MARK: Parsing

    /// Reads SRT or WebVTT (detected from the text). Bad blocks are skipped with a warning; nothing crashes.
    public static func parse(_ text: String, encoding: String = "UTF-8") throws -> SubtitleParseResult {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SubtitleError.notSubtitleText }
        let isVTT = trimmed.hasPrefix("WEBVTT")
        guard isVTT || trimmed.contains("-->") else { throw SubtitleError.notSubtitleText }

        var cues: [SubtitleCue] = []
        var warnings: [String] = []
        let blocks = normalized.components(separatedBy: "\n\n")
        for (bi, block) in blocks.enumerated() {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            guard !lines.isEmpty else { continue }
            if isVTT, let first = lines.first, first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") { continue }
            guard let arrowIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                if lines.count > 0, bi > 0 { warnings.append("Block \(bi + 1) has no time line and was skipped.") }
                continue
            }
            let parts = lines[arrowIndex].components(separatedBy: "-->")
            guard parts.count == 2, let s = parseTimestamp(parts[0]), let e = parseTimestamp(String(parts[1].split(separator: " ", omittingEmptySubsequences: true).first ?? "")) else {
                warnings.append("Block \(bi + 1): the time line “\(lines[arrowIndex])” could not be read.")
                continue
            }
            let body = lines[(arrowIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
            cues.append(SubtitleCue(start: s, end: e, text: body))
        }
        guard !cues.isEmpty else { throw SubtitleError.noCues }
        return SubtitleParseResult(cues: cues, warnings: warnings, encoding: encoding)
    }

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm` or VTT's `MM:SS.mmm`.
    static func parseTimestamp(_ raw: String) -> MediaTime? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0 else { return nil }
            if i > 0, v >= 60 { return nil }
            total = total * 60 + v
        }
        return MediaTime(seconds: total, timescale: 1000)
    }

    // MARK: Writing

    public enum Format { case srt, vtt }

    public static func serialize(_ cues: [SubtitleCue], format: Format, offsetSeconds: Double = 0) -> String {
        let sorted = cues.sorted { $0.start < $1.start }
        var out = format == .vtt ? "WEBVTT\n\n" : ""
        for (i, c) in sorted.enumerated() {
            let a = max(0, c.start.seconds + offsetSeconds), b = max(a, c.end.seconds + offsetSeconds)
            if format == .srt { out += "\(i + 1)\n" }
            out += "\(stamp(a, format)) --> \(stamp(b, format))\n\(c.text)\n\n"
        }
        return out
    }

    static func stamp(_ seconds: Double, _ f: Format) -> String {
        let ms = Int((seconds * 1000).rounded())
        let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, r = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, f == .srt ? "," : ".", r)
    }
}

// MARK: Editing

extension SubtitleDocument {
    public func cue(at t: MediaTime) -> SubtitleCue? { cues.first { $0.start <= t && t < $0.end } }

    public func issues(videoDuration: MediaTime?) -> [SubtitleIssue] {
        var out: [SubtitleIssue] = []
        let sorted = cues.sorted { $0.start < $1.start }
        for (i, c) in sorted.enumerated() {
            if c.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(SubtitleIssue(cueID: c.id, kind: .emptyText)) }
            if c.end <= c.start { out.append(SubtitleIssue(cueID: c.id, kind: .endsBeforeStart)) }
            if i > 0, c.start < sorted[i - 1].end { out.append(SubtitleIssue(cueID: c.id, kind: .overlapsPrevious)) }
            if let d = videoDuration {
                if c.start >= d { out.append(SubtitleIssue(cueID: c.id, kind: .startsAfterVideoEnds)) }
                else if c.end > d { out.append(SubtitleIssue(cueID: c.id, kind: .endsAfterVideoEnds)) }
            }
        }
        return out
    }

    public mutating func shiftAll(by seconds: Double) {
        let d = MediaTime(seconds: seconds, timescale: 1000)
        for i in cues.indices {
            // Never negative: a cue pushed before 0 is clamped, keeping its length.
            let len = cues[i].end - cues[i].start
            var s = cues[i].start + d
            if s < .zero { s = .zero }
            cues[i].start = s; cues[i].end = s + len
        }
    }

    public mutating func shift(ids: Set<UUID>, by seconds: Double) {
        let d = MediaTime(seconds: seconds, timescale: 1000)
        for i in cues.indices where ids.contains(cues[i].id) {
            let len = cues[i].end - cues[i].start
            var s = cues[i].start + d
            if s < .zero { s = .zero }
            cues[i].start = s; cues[i].end = s + len
        }
    }

    /// Joins neighbouring cues into one (text on separate lines), spanning from the first start to the last end.
    @discardableResult
    public mutating func merge(ids: Set<UUID>) -> UUID? {
        let chosen = cues.filter { ids.contains($0.id) }.sorted { $0.start < $1.start }
        guard chosen.count >= 2 else { return nil }
        var m = chosen[0]
        m.end = chosen.map(\.end).max()!
        m.text = chosen.map(\.text).joined(separator: "\n")
        cues.removeAll { ids.contains($0.id) }
        cues.append(m)
        cues.sort { $0.start < $1.start }
        return m.id
    }

    /// Splits one cue at `time`. Its text is divided at `textIndex` (characters), or at the middle line/word.
    @discardableResult
    public mutating func split(id: UUID, at time: MediaTime, textIndex: Int? = nil) -> (UUID, UUID)? {
        guard let i = cues.firstIndex(where: { $0.id == id }), time > cues[i].start, time < cues[i].end else { return nil }
        let c = cues[i]
        let chars = Array(c.text)
        var cut = textIndex ?? chars.count / 2
        if textIndex == nil, let nl = chars.firstIndex(of: "\n") { cut = nl }
        else if textIndex == nil, let sp = chars[min(cut, chars.count - 1)...].firstIndex(of: " ") { cut = sp }
        cut = max(0, min(cut, chars.count))
        let first = String(chars[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(chars[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var a = c, b = c
        a.end = time; a.text = first
        b.id = UUID(); b.start = time; b.text = second
        cues.replaceSubrange(i...i, with: [a, b])
        return (a.id, b.id)
    }

    /// Returns how many cues changed.
    @discardableResult
    public mutating func replace(_ find: String, with replacement: String, caseSensitive: Bool = false) -> Int {
        guard !find.isEmpty else { return 0 }
        var n = 0
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for i in cues.indices where cues[i].text.range(of: find, options: opts) != nil {
            cues[i].text = cues[i].text.replacingOccurrences(of: find, with: replacement, options: opts)
            n += 1
        }
        return n
    }

    public func find(_ query: String) -> [UUID] {
        guard !query.isEmpty else { return [] }
        return cues.filter { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
    }

    /// Cues limited to a range and re-based to start at 0, for exporting one clip with its own subtitles.
    public func cues(in span: TimeSpan) -> [SubtitleCue] {
        cues.compactMap { c in
            guard c.end > span.start, c.start < span.end else { return nil }
            var n = c
            n.start = max(c.start, span.start) - span.start
            n.end = min(c.end, span.end) - span.start
            return n
        }
    }
}
