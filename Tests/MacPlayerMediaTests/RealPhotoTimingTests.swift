import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Times the steps of saving one real photo. Runs only when `MACPLAYER_PHOTO_FILE` names a picture; the file is only read.
@Suite(.serialized) struct RealPhotoTimingTests {
    @Test func stepsOfSavingARealPhoto() throws {
        guard let path = ProcessInfo.processInfo.environment["MACPLAYER_PHOTO_FILE"] else { return }
        let url = URL(fileURLWithPath: path)
        func t<T>(_ label: String, _ f: () throws -> T) rethrows -> T { let s = Date(); let r = try f(); print("TIMING \(label): \(Int(Date().timeIntervalSince(s) * 1000)) ms"); return r }
        let info = try t("info") { try PhotoLoader.info(url: url) }
        print("TIMING size \(info.primaryVideo?.width ?? 0)x\(info.primaryVideo?.height ?? 0)")
        let loaded = try t("full load") { try PhotoLoader.full(url: url) }
        var look = VideoLook(); look.crop = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6); look.effects.filter = .vivid
        let scaled = loaded.image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1])
        let edited = t("render graph") { PhotoRenderer.render(base: scaled, look: look, overlays: []) }
        let cg = t("createCGImage") { PhotoRenderer.cgImage(edited, colorSpace: loaded.colorSpace) }
        print("TIMING cgimage \(cg.map { "\($0.width)x\($0.height)" } ?? "nil") space \(loaded.colorSpace?.name as String? ?? "none")")
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-timing-\(UUID().uuidString.prefix(6)).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        var o = PhotoExportOptions(); o.format = .jpeg; o.maxLongEdge = 2400
        let size = try t("whole export") { try PhotoExporter.export(source: url, look: look, overlays: [], options: o, to: out) }
        print("TIMING exported \(size.width)x\(size.height)")
    }
}
