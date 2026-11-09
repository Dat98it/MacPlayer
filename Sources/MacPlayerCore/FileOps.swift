import Foundation

public enum RenameError: Error, Equatable, Sendable {
    case sourceMissing
    case emptyName
    case invalidCharacters
    case hiddenName
    case tooLong
    case sameName
    /// Another file already has that name in the folder: nothing is overwritten, ever.
    case exists
    case failed(String)
}

/// Renaming a video file on the disk.
public enum FileOps {
    /// The name the file would get: what was typed (without a doubled extension) plus the file's own extension, which is kept.
    public static func newFileName(forTyped typed: String, oldPath: String) -> String {
        let ext = (oldPath as NSString).pathExtension
        var stem = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, stem.lowercased().hasSuffix("." + ext.lowercased()) { stem = String(stem.dropLast(ext.count + 1)).trimmingCharacters(in: .whitespaces) }
        return ext.isEmpty ? stem : stem + "." + ext
    }

    /// Checks a typed name; nil when it is fine.
    public static func problem(withTyped typed: String, oldPath: String) -> RenameError? {
        let name = newFileName(forTyped: typed, oldPath: oldPath)
        let ext = (oldPath as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        if stem.trimmingCharacters(in: .whitespaces).isEmpty || stem == "." || stem == ".." { return .emptyName }
        if stem.contains("/") || stem.contains(":") || stem.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return .invalidCharacters }
        if stem.hasPrefix(".") { return .hiddenName }
        if name.utf8.count > 255 { return .tooLong }
        if name == PathUtil.fileName(of: oldPath) { return .sameName }
        return nil
    }

    /// Renames the file inside its folder and returns its new path. Nothing is overwritten: a name that is taken is refused. A change of
    /// capital letters only ("Clip.mp4" to "clip.mp4"), which a disk that ignores case sees as the same name, goes through a temporary name.
    @discardableResult
    public static func rename(_ path: String, toTyped typed: String, fs: FileSystem) throws -> String {
        guard fs.exists(path) else { throw RenameError.sourceMissing }
        if let p = problem(withTyped: typed, oldPath: path) { throw p }
        let name = newFileName(forTyped: typed, oldPath: path)
        let dest = PathUtil.join(PathUtil.directory(of: path), name)
        let caseOnly = name.lowercased() == PathUtil.fileName(of: path).lowercased()
        do {
            if caseOnly {
                let temp = PathUtil.join(PathUtil.directory(of: path), ".\(UUID().uuidString.prefix(8)).macplayer-rename")
                try fs.move(from: path, to: temp)
                do { try fs.move(from: temp, to: dest) } catch { try? fs.move(from: temp, to: path); throw error }
            } else {
                guard !fs.exists(dest) else { throw RenameError.exists }
                try fs.move(from: path, to: dest)
            }
        } catch let e as RenameError { throw e }
        catch { throw RenameError.failed(error.localizedDescription) }
        return dest
    }
}
