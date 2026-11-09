import CoreImage
import Foundation
import MacPlayerCore

/// The colour of a picture as Core Image recipes: the four basic sliders as they always were, then the finer tools (exposure, shadows and
/// highlights, vibrance, tint, curves, wheels, HSL, a look file) in one pass through a colour cube. Used by the one renderer behind
/// preview, export and the small pictures of the interface, so all of them agree.
enum ColorGradeRenderer {
    static let cubeSize = 33

    static func apply(_ c: ColorAdjust, to image: CIImage) -> CIImage {
        var out = image
        let basic = c.brightness != 0 || c.contrast != 0 || c.saturation != 0 || c.temperature != 0
        if basic {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: c.brightness * 0.5, kCIInputContrastKey: 1 + c.contrast * 0.5, kCIInputSaturationKey: 1 + c.saturation,
            ])
            if c.temperature != 0 {
                // Warmer = lower target neutral temperature.
                out = out.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - c.temperature * 2500, y: 0),
                ])
            }
        }
        if c.needsGrade {
            let extent = out.extent
            // The cube works on the values as stored (the renderer's contexts do no colour management), which is what curves expect.
            out = out.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": cubeSize, "inputCubeData": ColorCubeCache.data(for: c)]).cropped(to: extent)
        }
        return out
    }
}

/// The colour cubes already worked out (one per set of settings; scrubbing a slider makes many, so only the latest few are kept) and the
/// look files already read. A cube is made the first time a frame needs it, not once per frame.
enum ColorCubeCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cubes: [ColorAdjust: Data] = [:]
    nonisolated(unsafe) private static var order: [ColorAdjust] = []

    static func data(for c: ColorAdjust) -> Data {
        lock.lock(); if let hit = cubes[c] { lock.unlock(); return hit }; lock.unlock()
        let lut = c.lut.flatMap { LutStore.lut(atPath: $0.path) }
        let floats = ColorGrading.cube(for: c, lut: lut, size: ColorGradeRenderer.cubeSize)
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); defer { lock.unlock() }
        cubes[c] = data; order.append(c)
        while order.count > 12 { cubes[order.removeFirst()] = nil }
        return data
    }

    static func clear() { lock.lock(); cubes.removeAll(); order.removeAll(); lock.unlock() }
}

/// Look files (`.cube`) read from disk, once each. A file that cannot be read is remembered too, until `forget` is called, so a missing
/// file is not looked for at every frame.
public enum LutStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: CubeLUT?] = [:]

    static func lut(atPath path: String) -> CubeLUT? {
        lock.lock(); if let hit = loaded[path] { lock.unlock(); return hit }; lock.unlock()
        let lut = try? CubeLUT.parse(String(contentsOfFile: path, encoding: .utf8))
        lock.lock(); loaded[path] = .some(lut); lock.unlock()
        return lut
    }

    /// Reads a look file for the person to see why it fails (or to use it right away).
    public static func read(path: String) throws -> CubeLUT {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let lut = try CubeLUT.parse(text)
        lock.lock(); loaded[path] = .some(lut); lock.unlock()
        ColorCubeCache.clear()
        return lut
    }

    public static func forget(path: String) { lock.lock(); loaded[path] = nil; lock.unlock(); ColorCubeCache.clear() }
    public static func isUsable(path: String) -> Bool { lut(atPath: path) != nil }
}

/// The colour of the clip being edited, handed to a preview that is already playing so a slider shows at the next frame without building the
/// preview again (the same idea as `EffectsLive`). Only previews read it; an export always uses the settings it was given.
public enum ColorLive {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [UUID: ColorAdjust] = [:]
    public static func set(_ colour: ColorAdjust, for key: UUID) { lock.lock(); overrides[key] = colour; lock.unlock() }
    public static func clear() { lock.lock(); overrides.removeAll(); lock.unlock() }
    static func colour(for key: UUID) -> ColorAdjust? { lock.lock(); defer { lock.unlock() }; return overrides[key] }
}
