import Foundation

/// File names for exported clips: tokens, safe characters, and no collisions (design section 11).
public struct NamingTemplate: Codable, Equatable, Sendable {
    /// Tokens: {source} source file name, {name} clip name, {index} 1-based, zero-padded to the batch size,
    /// {timecode} clip start as HH-MM-SS, {date} yyyy-MM-dd.
    public var pattern: String

    public static let `default` = NamingTemplate(pattern: "{source} - {index} - {name}")

    public init(pattern: String) { self.pattern = pattern }

    public func render(source: String, name: String, index: Int, total: Int, start: MediaTime, date: Date) -> String {
        let width = max(2, String(total).count)
        let secs = max(0, Int(start.seconds))
        let tc = String(format: "%02d-%02d-%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        var out = pattern
        out = out.replacingOccurrences(of: "{source}", with: source)
        out = out.replacingOccurrences(of: "{name}", with: name)
        out = out.replacingOccurrences(of: "{index}", with: String(format: "%0\(width)d", index))
        out = out.replacingOccurrences(of: "{timecode}", with: tc)
        out = out.replacingOccurrences(of: "{date}", with: df.string(from: date))
        let clean = Self.sanitize(out)
        return clean.isEmpty ? Self.sanitize(source) : clean
    }

    /// Removes what no file name may contain, collapses runs of spaces, and keeps the name under the
    /// 255-byte limit of APFS without cutting a multi-byte (Vietnamese) character in half.
    public static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var out = String(String.UnicodeScalarView(s.unicodeScalars.map { bad.contains($0) ? " " : $0 }))
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        while out.utf8.count > 200 { out.removeLast() }
        return out
    }
}

public struct PlannedOutput: Equatable, Sendable {
    public var selectionID: UUID
    public var path: String
    public var name: String
    public var span: TimeSpan
}

public struct BatchIssue: Equatable, Sendable {
    public init(kind: Kind) { self.kind = kind }
    public enum Kind: Equatable, Sendable {
        case folderMissing, folderNotWritable, notEnoughSpace(needed: Int64, available: Int64)
        case destinationIsSource(String), emptySelection
    }
    public var kind: Kind
}

/// The list of files a batch export will make, decided and checked before anything runs.
public struct BatchPlan: Equatable, Sendable {
    public var outputs: [PlannedOutput]
    public var issues: [BatchIssue]
    /// Names that had to be changed to avoid an existing file or another clip in the batch.
    public var renamedForConflict: [String]

    public var canRun: Bool { issues.isEmpty && !outputs.isEmpty }

    public static func make(selections: [ClipSelection], sourcePath: String, folder: String, fileExtension: String,
                            template: NamingTemplate, fs: FileSystem, estimatedBytesPerSecond: Double, date: Date = Date()) -> BatchPlan {
        var issues: [BatchIssue] = []
        guard !selections.isEmpty else { return BatchPlan(outputs: [], issues: [BatchIssue(kind: .emptySelection)], renamedForConflict: []) }
        if !fs.isDirectory(folder) { issues.append(BatchIssue(kind: .folderMissing)) }
        else if !fs.isWritable(folder) { issues.append(BatchIssue(kind: .folderNotWritable)) }

        let sourceStem = PathUtil.stem(of: sourcePath)
        var taken = Set<String>()
        var outputs: [PlannedOutput] = []
        var renamed: [String] = []
        for (i, s) in selections.enumerated() {
            let base = template.render(source: sourceStem, name: s.name, index: i + 1, total: selections.count, start: s.start, date: date)
            var candidate = base, n = 2
            func path(_ stem: String) -> String { PathUtil.join(folder, "\(stem).\(fileExtension)") }
            // Case-insensitive on purpose: APFS volumes usually are, and two names differing by case would collide.
            while taken.contains(path(candidate).lowercased()) || fs.exists(path(candidate)) { candidate = "\(base) \(n)"; n += 1 }
            if candidate != base { renamed.append(candidate) }
            taken.insert(path(candidate).lowercased())
            let p = path(candidate)
            if BatchPlan.samePath(p, sourcePath) { issues.append(BatchIssue(kind: .destinationIsSource(p))) }
            outputs.append(PlannedOutput(selectionID: s.id, path: p, name: candidate, span: s.span))
        }
        let total = selections.reduce(0.0) { $0 + $1.duration.seconds }
        let needed = Int64(total * estimatedBytesPerSecond * 1.05)
        if fs.isDirectory(folder), needed > 0, let avail = try? fs.freeSpace(atPath: folder), avail < needed {
            issues.append(BatchIssue(kind: .notEnoughSpace(needed: needed, available: avail)))
        }
        return BatchPlan(outputs: outputs, issues: issues, renamedForConflict: renamed)
    }

    static func samePath(_ a: String, _ b: String) -> Bool { PathUtil.same(a, b) }
}
