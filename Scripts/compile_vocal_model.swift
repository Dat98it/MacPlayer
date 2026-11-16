import Foundation
import CoreML
import CryptoKit

// Compile locally; the installed app never downloads a model or sends audio to a service.
let args = CommandLine.arguments
guard args.count == 3 else { fatalError("compile_vocal_model.swift <model.mlpackage> <destination.mlmodelc>") }
let source = URL(fileURLWithPath: args[1]), destination = URL(fileURLWithPath: args[2])
let pins = [
    "Manifest.json": "6d4940ef8e0f2f1de2bc83ff675548206af160c66ee44f25fcdda19dcd000d38",
    "Data/com.apple.CoreML/model.mlmodel": "fe4055846ccddb4a04765feb20ec7fe6530624383323782a91d125f760f05ac4",
    "Data/com.apple.CoreML/weights/weight.bin": "0a687c627a66e8dc3dc6947e31d35526164f234757208624506ff2aaf47bd1a5",
]
for (path, expected) in pins {
    let bytes = try Data(contentsOf: source.appendingPathComponent(path))
    let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard actual == expected else { fatalError("Instrumental model checksum failed: \(path)") }
}
let compiled = try MLModel.compileModel(at: source)
defer { try? FileManager.default.removeItem(at: compiled) }
try FileManager.default.copyItem(at: compiled, to: destination)
