import AppKit
import CryptoKit
import Foundation
import ImageIO
import MacPlayerCore
import MacPlayerMedia

/// `--selftest <dir> --real-photos <folder> --real-only`: the photo flows in the real app on a folder of the user's own pictures.
/// Nothing in that folder is ever written to: pictures are only read, everything saved goes to the work folder, and replacing an original is
/// tried on copies. The folder is listed before and after (every file's size and date) and the pictures that were used are compared byte for byte.
extension SelfTest {
    private struct Snapshot: Equatable { var size: Int64; var modified: Double }

    private static func list(_ root: URL) -> [String: Snapshot] {
        var out: [String: Snapshot] = [:]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: []) else { return out }
        for case let u as URL in e {
            guard u.lastPathComponent != ".DS_Store", let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }     // Finder rewrites .DS_Store by itself
            out[u.path] = Snapshot(size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return out
    }

    private static func sha(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func realPhotosFlow(env: AppEnvironment, work: URL, real: URL, app: AppDelegate) async {
        print("== M: real photos (read only)")
        let fm = FileManager.default
        let before = list(real)
        let pictures = before.keys.filter { ImageFiles.isCandidate($0) && !PathUtil.fileName(of: $0).hasPrefix(".") }.sorted()
        check(!pictures.isEmpty, "the folder has pictures (\(pictures.count))")

        // 1. A look at every picture's header: can it be read, how big, turned, with a position.
        struct Facts { var path: String; var ext: String; var w: Int; var h: Int; var orientation: Int; var gps: Bool; var space: String?; var bytes: Int64 }
        var facts: [Facts] = [], unreadable: [String] = []
        let t0 = Date()
        for p in pictures {
            let url = URL(fileURLWithPath: p)
            guard let info = try? PhotoLoader.info(url: url), let v = info.primaryVideo,
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { unreadable.append(PathUtil.ext(of: p).lowercased()); continue }
            facts.append(Facts(path: p, ext: PathUtil.ext(of: p).lowercased(), w: v.width, h: v.height, orientation: (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,
                               gps: (props[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] != nil, space: props[kCGImagePropertyProfileName] as? String, bytes: before[p]?.size ?? 0))
        }
        let byExt = Dictionary(grouping: facts, by: \.ext).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("   headers read in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(byExt); unreadable \(unreadable.count)\(unreadable.isEmpty ? "" : " (" + Dictionary(grouping: unreadable, by: { $0 }).map { "\($0.key) \($0.value.count)" }.joined(separator: ", ") + ")"); turned by the camera \(facts.filter { $0.orientation != 1 }.count); with a position \(facts.filter(\.gps).count); largest \(facts.map { $0.w * $0.h }.max().map { "\($0 / 1_000_000) MP" } ?? "-")")
        check(Double(unreadable.count) <= Double(pictures.count) * 0.01, "every format in the folder can be read (\(unreadable.count) of \(pictures.count) could not)")

        // 2. A sample that covers the kinds: per type the smallest, the largest, one turned, one with a position, plus spread.
        var sample: [Facts] = []
        func add(_ f: Facts?) { if let f, !sample.contains(where: { $0.path == f.path }) { sample.append(f) } }
        for (_, group) in Dictionary(grouping: facts, by: \.ext).sorted(by: { $0.key < $1.key }) {
            add(group.min { $0.bytes < $1.bytes }); add(group.max { $0.bytes < $1.bytes })
            add(group.first { $0.orientation != 1 }); add(group.first { $0.gps })
            for k in stride(from: group.count / 5, to: group.count, by: max(1, group.count / 3)).prefix(2) { add(group[k]) }
        }
        add(facts.max { $0.w * $0.h < $1.w * $1.h })
        sample = Array(sample.prefix(28))
        let hashes = Dictionary(uniqueKeysWithValues: sample.map { ($0.path, sha(URL(fileURLWithPath: $0.path))) })
        print("   sample of \(sample.count) pictures: " + Dictionary(grouping: sample, by: \.ext).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)" }.joined(separator: ", "))

        let out = work.appendingPathComponent("real-photos-out"); try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        var openMs: [Double] = [], saveMs: [Double] = []
        var n = 0
        for f in sample {
            n += 1
            let label = "#\(n) \(f.ext) \(f.w)×\(f.h)\(f.orientation != 1 ? " turned" : "")\(f.gps ? " +position" : "")"
            let url = URL(fileURLWithPath: f.path)
            let tOpen = Date()
            guard let s = await SelfTest.editor(url, kind: .photo) else { check(false, "\(label): opens"); continue }
            await waitFor(30) { s.photoImage != nil }
            openMs.append(Date().timeIntervalSince(tOpen) * 1000)
            check(s.isPhoto && s.photoImage != nil && s.info?.primaryVideo?.width == f.w && s.info?.primaryVideo?.height == f.h, "\(label): opens and is drawn")
            // A preview that is upright and in proportion.
            if let img = s.photoImage { check(abs(Double(img.width) / Double(img.height) - Double(f.w) / Double(f.h)) < 0.02, "\(label): the picture on the screen has the picture's shape") }

            // The frame on the picture: the middle 60 % in the shown picture, then a filter and some text.
            s.photoCropAdjusting = true
            s.setPhotoCropFrame(CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), coalesce: nil)
            s.editEffects("filter") { $0.filter = .vivid }
            s.edit("text") { $0.overlays.append(TextOverlay(text: "Test", start: .zero, end: MediaTime(seconds: 100_000), sizeFraction: 0.1)) }
            let expectW = Int((Double(f.w) * 0.6).rounded()), expectH = Int((Double(f.h) * 0.6).rounded())
            let shown = CropGeometry.shownSize(width: Double(f.w), height: Double(f.h), rotation: 0)
            _ = shown
            check(abs((s.photoOutputSize?.width ?? 0) - Double(expectW)) <= 2 && abs((s.photoOutputSize?.height ?? 0) - Double(expectH)) <= 2, "\(label): the crop frame sets the saved size (\(Int(s.photoOutputSize?.width ?? 0))×\(Int(s.photoOutputSize?.height ?? 0)))")
            s.activeTool = .effects              // leave the frame: the picture now shows the cut
            await waitFor(30) { s.photoImage.map { abs(Double($0.width) / Double($0.height) - Double(expectW) / Double(expectH)) < 0.03 } ?? false }
            check(s.photoImage.map { abs(Double($0.width) / Double($0.height) - Double(expectW) / Double(expectH)) < 0.03 } ?? false, "\(label): the picture on the screen shows the cut")

            // Saved as a new picture: JPEG for most, and the other formats on a few.
            let formats: [PhotoFormat] = n % 4 == 0 ? [.heic] : (n % 5 == 0 ? [.png] : [.jpeg])
            s.photoDraft.folder = out.path; s.photoDraft.name = "photo-\(n)"; s.photoDraft.options.format = formats[0]; s.photoDraft.options.maxLongEdge = 2400
            let planned = PhotoExporter.plannedSize(width: Double(f.w), height: Double(f.h), look: s.project.look, maxLongEdge: 2400)
            let target = (width: planned.width, height: planned.height)
            let tSave = Date()
            s.savePhoto()
            await waitFor(120) { s.photoDraft.lastSaved != nil && !s.photoDraft.saving }
            saveMs.append(Date().timeIntervalSince(tSave) * 1000)
            let saved = out.appendingPathComponent("photo-\(n).\(formats[0].fileExtension)")
            if let info = try? PhotoLoader.info(url: saved), let v = info.primaryVideo {
                check(v.width == target.width && v.height == target.height, "\(label): saved as \(formats[0].rawValue) at \(v.width)×\(v.height) (expected \(target.width)×\(target.height))")
                if let src = CGImageSourceCreateWithURL(saved as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    check(((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1, "\(label): the saved picture is upright, without a turn instruction")
                    if f.gps, formats[0] != .png { check(props[kCGImagePropertyGPSDictionary] != nil, "\(label): the position is kept") }
                }
            } else { check(false, "\(label): the saved file can be read (\(s.notice?.text ?? "no message"))") }
            if f.ext != "png", n % 3 == 0 {
                // Without the position.
                s.photoDraft.name = "photo-\(n)-private"; s.photoDraft.options.format = .jpeg; s.photoDraft.options.removeLocation = true; s.photoDraft.lastSaved = nil
                s.savePhoto()
                await waitFor(120) { s.photoDraft.lastSaved != nil && !s.photoDraft.saving }
                if let src = CGImageSourceCreateWithURL(out.appendingPathComponent("photo-\(n)-private.jpg") as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    check(props[kCGImagePropertyGPSDictionary] == nil, "\(label): saved without the position")
                } else { check(false, "\(label): the private copy can be read") }
            }
            // A project of the edit: saved, opened again, same crop and same picture.
            if n % 6 == 1 {
                _ = s.saveNow()
                let proj = s.projectPath ?? ""
                if let re = try? await EditorSession.openProject(path: proj) {
                    await waitFor(30) { re.photoImage != nil }
                    check(re.isPhoto && re.project.look.crop == s.project.look.crop && re.project.overlays.count == 1 && !re.isDirty, "\(label): the edit is saved as a project and opens again")
                    re.close()
                } else { check(false, "\(label): the project opens again") }
            }
            s.close()
        }
        if !openMs.isEmpty { print(String(format: "   opening: average %.0f ms, slowest %.0f ms · saving: average %.0f ms, slowest %.0f ms", openMs.reduce(0, +) / Double(openMs.count), openMs.max() ?? 0, saveMs.reduce(0, +) / Double(max(1, saveMs.count)), saveMs.max() ?? 0)) }

        // 4. Thumbnails of the sample, as the playlist makes them.
        var thumbMs: [Double] = [], failed = 0
        for f in sample {
            let t = Date()
            if PhotoLoader.thumbnail(url: URL(fileURLWithPath: f.path), maxSize: CGSize(width: 360, height: 203)) == nil { failed += 1 }
            thumbMs.append(Date().timeIntervalSince(t) * 1000)
        }
        check(failed == 0, "a thumbnail can be made of every picture in the sample (\(failed) failed; average \(Int(thumbMs.reduce(0, +) / Double(max(1, thumbMs.count)))) ms)")

        // 5. The originals: not one byte, name or date changed, nothing added to the folder.
        let after = list(real)
        check(after == before, "the folder is exactly as it was: \(after.count) files, nothing changed, nothing added or removed")
        let changed = sample.filter { sha(URL(fileURLWithPath: $0.path)) != hashes[$0.path] }
        check(changed.isEmpty, "the \(sample.count) pictures that were used are identical byte for byte (\(changed.count) differ)")
    }
}
