import Foundation

public enum MarkerColor: String, Codable, CaseIterable, Sendable { case red, orange, yellow, green, blue, purple, gray }

public struct Marker: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var time: MediaTime
    public var name: String
    public var color: MarkerColor
    public var note: String

    public init(id: UUID = UUID(), time: MediaTime, name: String = "", color: MarkerColor = .blue, note: String = "") {
        self.id = id; self.time = time; self.name = name; self.color = color; self.note = note
    }
}

/// A named part of the video the user wants to keep: In/Out plus what to call it and how to export it.
public struct ClipSelection: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var start: MediaTime
    public var end: MediaTime
    /// Export preset to use for this clip; nil means the batch's shared preset.
    public var presetID: String?
    /// Still image chosen for this clip (design section 9, "thumbnail riêng cho mỗi đoạn xuất hàng loạt").
    public var thumbnailTime: MediaTime?

    public init(id: UUID = UUID(), name: String, start: MediaTime, end: MediaTime, presetID: String? = nil, thumbnailTime: MediaTime? = nil) {
        self.id = id; self.name = name; self.start = start; self.end = end; self.presetID = presetID; self.thumbnailTime = thumbnailTime
    }

    public var span: TimeSpan { TimeSpan(start: start, end: end) }
    public var duration: MediaTime { end - start }
}

/// What to do when selections overlap. Never decided silently (design section 5).
public enum OverlapPolicy: String, Codable, CaseIterable, Sendable {
    case keepSeparate
    case merge
}

public struct SelectionList: Codable, Equatable, Sendable {
    public var items: [ClipSelection] = []
    public var overlapPolicy: OverlapPolicy = .keepSeparate

    public init(items: [ClipSelection] = [], overlapPolicy: OverlapPolicy = .keepSeparate) {
        self.items = items; self.overlapPolicy = overlapPolicy
    }

    /// Adds a selection, ordered by start time. In/Out are swapped if given backwards; empty ranges are refused.
    @discardableResult
    public mutating func add(start: MediaTime, end: MediaTime, name: String? = nil, duration: MediaTime? = nil) -> ClipSelection? {
        var a = min(start, end), b = max(start, end)
        if let d = duration { a = max(a, .zero); b = min(b, d) }
        guard b > a else { return nil }
        let sel = ClipSelection(name: name ?? nextDefaultName(), start: a, end: b)
        items.append(sel)
        items.sort { $0.start < $1.start }
        return sel
    }

    func nextDefaultName() -> String {
        var n = items.count + 1
        let names = Set(items.map(\.name))
        while names.contains("Clip \(n)") { n += 1 }
        return "Clip \(n)"
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items[i].name = trimmed.isEmpty ? items[i].name : trimmed
    }

    public mutating func setRange(_ id: UUID, start: MediaTime, end: MediaTime, duration: MediaTime? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var a = min(start, end), b = max(start, end)
        if let d = duration { a = max(a, .zero); b = min(b, d) }
        guard b > a else { return }
        items[i].start = a; items[i].end = b
    }

    public mutating func remove(_ ids: Set<UUID>) { items.removeAll { ids.contains($0.id) } }

    @discardableResult
    public mutating func duplicate(_ id: UUID) -> ClipSelection? {
        guard let s = items.first(where: { $0.id == id }) else { return nil }
        var copy = s
        copy.id = UUID()
        copy.name = s.name + " copy"
        items.append(copy)
        items.sort { $0.start < $1.start }
        return copy
    }

    /// Manual order (for export order and numbering) when the user drags rows. Start-time order is the default.
    public mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        var arr = items
        let moving = fromOffsets.sorted().map { arr[$0] }
        for i in fromOffsets.sorted(by: >) { arr.remove(at: i) }
        let dest = toOffset - fromOffsets.filter { $0 < toOffset }.count
        arr.insert(contentsOf: moving, at: max(0, min(dest, arr.count)))
        items = arr
    }

    public func overlappingPairs() -> [(UUID, UUID)] {
        var out: [(UUID, UUID)] = []
        for i in items.indices { for j in items.indices where j > i && items[i].span.overlaps(items[j].span) { out.append((items[i].id, items[j].id)) } }
        return out
    }

    public var hasOverlaps: Bool { !overlappingPairs().isEmpty }

    /// The selections that will actually be exported, after applying the overlap policy.
    public func effective() -> [ClipSelection] {
        guard overlapPolicy == .merge else { return items }
        var result: [ClipSelection] = []
        for s in items.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, s.start < last.end {
                last.end = max(last.end, s.end)
                result[result.count - 1] = last
            } else {
                result.append(s)
            }
        }
        return result
    }

    public var totalDuration: MediaTime { effective().reduce(.zero) { $0 + $1.duration } }
}

/// CSV and JSON for markers and clip lists (design section 5), so they can be reused outside the app.
public enum ListExport {
    public static func csv(selections: [ClipSelection], frameRate: FrameRate) -> String {
        var lines = ["index,name,start,end,duration"]
        for (i, s) in selections.enumerated() {
            lines.append([String(i + 1), quote(s.name), Timecode.format(s.start, frameRate: frameRate), Timecode.format(s.end, frameRate: frameRate),
                          Timecode.format(s.duration)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func csv(markers: [Marker], frameRate: FrameRate) -> String {
        var lines = ["time,name,color,note"]
        for m in markers.sorted(by: { $0.time < $1.time }) {
            lines.append([Timecode.format(m.time, frameRate: frameRate), quote(m.name), m.color.rawValue, quote(m.note)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// CSV quoting that survives commas, quotes, line breaks and Vietnamese text.
    static func quote(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public struct Document: Codable, Equatable, Sendable {
        public var version = 1
        public var selections: [ClipSelection]
        public var markers: [Marker]
        public init(selections: [ClipSelection], markers: [Marker]) { self.selections = selections; self.markers = markers }
    }

    public static func json(selections: [ClipSelection], markers: [Marker]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(Document(selections: selections, markers: markers))
    }

    public static func parseJSON(_ data: Data) throws -> Document { try JSONDecoder().decode(Document.self, from: data) }
}
