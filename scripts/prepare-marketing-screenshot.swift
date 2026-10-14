#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Preserve the native screenshot dimensions and pixels while removing an opaque alpha channel.
// This script never crops, scales, adds artwork, or creates app content.
func fail(_ message: String) -> Never {
    fputs("Screenshot validation failed: \(message)\n", stderr)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 5, let width = Int(arguments[3]), let height = Int(arguments[4]), width < height else {
    fail("Usage: swift scripts/prepare-marketing-screenshot.swift input.png output.png width height")
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      CGImageSourceGetType(source) == UTType.png.identifier as CFString,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == width, image.height == height,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fail("Input must be a PNG captured at the requested native portrait dimensions.")
}
let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation != 1 {
    fail("Input must already be upright.")
}
var rgba = [UInt8](repeating: 0, count: width * height * 4)
let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard rendered else { fail("Unable to decode screenshot.") }
var rgb = Data(capacity: width * height * 3)
for offset in stride(from: 0, to: rgba.count, by: 4) {
    guard rgba[offset + 3] == 255 else { fail("Input contains transparent pixels.") }
    rgb.append(contentsOf: rgba[offset..<(offset + 3)])
}
guard let provider = CGDataProvider(data: rgb as CFData),
      let opaqueImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                bytesPerRow: width * 3, space: colorSpace,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("Unable to create RGB output.")
}
CGImageDestinationAddImage(destination, opaqueImage, nil)
guard CGImageDestinationFinalize(destination), let png = try? Data(contentsOf: outputURL),
      png.count > 26, png[24] == 8, png[25] == 2 else {
    fail("Output must be an 8-bit RGB PNG with no alpha channel.")
}
print("Verified \(outputURL.lastPathComponent): \(width) x \(height), PNG, RGB, opaque, upright portrait.")
