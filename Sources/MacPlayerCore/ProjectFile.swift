import Foundation

/// The project files the app saves and opens. Projects made while the app was still called MacVideo end in `.macvideo`; they still open.
public enum ProjectFile {
    public static let fileExtension = "macplayer"
    public static let legacyExtension = "macvideo"
    public static let allExtensions = [fileExtension, legacyExtension]

    public static func isProject(extension ext: String) -> Bool { allExtensions.contains(ext.lowercased()) }
    public static func isProject(path: String) -> Bool { isProject(extension: (path as NSString).pathExtension) }
    public static func isProject(_ url: URL) -> Bool { isProject(extension: url.pathExtension) }
}
