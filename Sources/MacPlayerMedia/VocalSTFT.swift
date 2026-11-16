import Accelerate
import CoreML
import Foundation

/// UVR MDX-Net's unnormalised, centred STFT. The learned network takes complex stereo planes,
/// not magnitudes: preserving phase and the periodic Hann window is essential to separation quality.
final class VocalSTFT {
    static let size = 6144, hop = 1024, bins = 3072, frames = 256
    static let samples = hop * (frames - 1)
    static let trim = size / 2
    static let step = samples - 2 * trim
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private let window: [Float]

    init() throws {
        guard let f = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD) else { throw VocalRemover.Failure.transform }
        guard let i = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .INVERSE) else {
            vDSP_DFT_DestroySetup(f); throw VocalRemover.Failure.transform
        }
        forward = f; inverse = i
        window = (0..<Self.size).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(Self.size))) }
    }

    deinit { vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse) }

    func spectrum(_ channels: [[Float]], removeLowBins: Bool = true) throws -> MLMultiArray {
        guard channels.count == 2, channels.allSatisfy({ $0.count == Self.samples }) else { throw VocalRemover.Failure.transform }
        let tensor = try MLMultiArray(shape: [1, 4, Self.bins as NSNumber, Self.frames as NSNumber], dataType: .float16)
        let strides = tensor.strides.map(\.intValue)
        let pointer = tensor.dataPointer.assumingMemoryBound(to: Float16.self)
        var real = [Float](repeating: 0, count: Self.size), imag = real, re = real, im = real
        for channel in 0..<2 {
            for frame in 0..<Self.frames {
                try Task.checkCancellation()
                let start = frame * Self.hop - Self.trim
                for j in 0..<Self.size {
                    var index = start + j
                    if index < 0 { index = -index }
                    if index >= Self.samples { index = 2 * Self.samples - 2 - index }
                    real[j] = channels[channel][index] * window[j]
                }
                vDSP_DFT_Execute(forward, real, imag, &re, &im)
                for bin in 0..<Self.bins {
                    let offset = 2 * channel * strides[1] + bin * strides[2] + frame * strides[3]
                    pointer[offset] = removeLowBins && bin < 3 ? 0 : Float16(re[bin])
                    pointer[offset + strides[1]] = removeLowBins && bin < 3 ? 0 : Float16(im[bin])
                }
            }
        }
        return tensor
    }

    func waveform(_ tensor: MLMultiArray) throws -> [[Float]] {
        guard tensor.shape.map(\.intValue) == [1, 4, Self.bins, Self.frames], tensor.dataType == .float16 else { throw VocalRemover.Failure.model }
        let strides = tensor.strides.map(\.intValue)
        let pointer = tensor.dataPointer.assumingMemoryBound(to: Float16.self)
        var norm = [Float](repeating: 0, count: Self.samples + Self.size)
        for frame in 0..<Self.frames {
            for j in 0..<Self.size { norm[frame * Self.hop + j] += window[j] * window[j] }
        }
        var result: [[Float]] = []
        for channel in 0..<2 {
            var output = [Float](repeating: 0, count: norm.count)
            var real = [Float](repeating: 0, count: Self.size), imag = real, re = real, im = real
            for frame in 0..<Self.frames {
                try Task.checkCancellation()
                for bin in 0..<Self.bins {
                    let offset = 2 * channel * strides[1] + bin * strides[2] + frame * strides[3]
                    real[bin] = Float(pointer[offset]); imag[bin] = Float(pointer[offset + strides[1]])
                    if bin > 0 { real[Self.size - bin] = real[bin]; imag[Self.size - bin] = -imag[bin] }
                }
                real[Self.bins] = 0; imag[Self.bins] = 0; imag[0] = 0
                vDSP_DFT_Execute(inverse, real, imag, &re, &im)
                for j in 0..<Self.size { output[frame * Self.hop + j] += re[j] * window[j] / Float(Self.size) }
            }
            var wave = [Float](repeating: 0, count: Self.samples)
            for j in wave.indices {
                let value = output[j + Self.trim] / max(1e-8, norm[j + Self.trim])
                guard value.isFinite else { throw VocalRemover.Failure.model }
                wave[j] = value
            }
            result.append(wave)
        }
        return result
    }
}
