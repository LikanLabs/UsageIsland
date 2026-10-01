// Turns a short screen recording into a looping GIF for the README.
// Usage: swift Scripts/make-readme-gif.swift <input.mov> <output.gif> [fps] [maxWidth] [start] [end]
// Defaults: 12 fps, 720 px wide, the whole clip. Uses only system frameworks.
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("Usage: make-readme-gif.swift <input.mov> <output.gif> [fps] [maxWidth] [start] [end]\n".utf8))
    exit(1)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let fps = arguments.count > 3 ? Double(arguments[3]) ?? 12 : 12
let maxWidth = arguments.count > 4 ? Double(arguments[4]) ?? 720 : 720

let asset = AVURLAsset(url: input)
let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var duration = CMTime.zero
nonisolated(unsafe) var naturalSize = CGSize.zero
Task {
    duration = (try? await asset.load(.duration)) ?? .zero
    if let track = try? await asset.loadTracks(withMediaType: .video).first,
       let size = try? await track.load(.naturalSize),
       let transform = try? await track.load(.preferredTransform) {
        let rotated = size.applying(transform)
        naturalSize = CGSize(width: abs(rotated.width), height: abs(rotated.height))
    }
    semaphore.signal()
}
semaphore.wait()

let total = duration.seconds
let start = arguments.count > 5 ? Double(arguments[5]) ?? 0 : 0
let end = min(arguments.count > 6 ? Double(arguments[6]) ?? total : total, total)
guard total > 0, end > start, naturalSize.width > 0 else {
    FileHandle.standardError.write(Data("Could not read the video.\n".utf8))
    exit(1)
}

let scale = min(1, maxWidth / naturalSize.width)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)

let frameCount = Int(((end - start) * fps).rounded(.down))
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
    FileHandle.standardError.write(Data("Could not create the GIF.\n".utf8))
    exit(1)
}
CGImageDestinationSetProperties(destination, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary)
let frameProperties = [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps],
] as CFDictionary

nonisolated(unsafe) var frames: [CGImage] = []
Task {
    for index in 0..<frameCount {
        let time = CMTime(seconds: start + Double(index) / fps, preferredTimescale: 600)
        if let (image, _) = try? await generator.image(at: time) { frames.append(image) }
    }
    semaphore.signal()
}
semaphore.wait()
for image in frames {
    CGImageDestinationAddImage(destination, image, frameProperties)
}
let written = frames.count
guard written > 0, CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("No frames were written.\n".utf8))
    exit(1)
}
let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print("Wrote \(output.lastPathComponent): \(written) frames, \(Int(generator.maximumSize.width))×\(Int(generator.maximumSize.height)) px, \(bytes / 1024) KB")
