import Foundation
import AppKit
import CoreGraphics

/// A midtone brightness curve that keeps pure black and pure white where they are, so nothing clips.
/// Slider value 0 does nothing, +10 is a touch lighter, -10 a touch darker.
enum Brightness {
    static let range: ClosedRange<Double> = -50...50

    static func exponent(_ v: Double) -> Double { pow(2, -v / 100) }

    /// Adjusts an RGBX buffer in place (3 color channels, the 4th is skipped). 8 or 16 bits per channel.
    static func apply(_ v: Double, data: UnsafeMutableRawPointer, bits: Int, width: Int, height: Int, stride: Int) {
        guard v != 0 else { return }
        let e = exponent(v)
        if bits == 16 {
            var lut = [UInt16](repeating: 0, count: 65536)
            for i in 0..<65536 { lut[i] = UInt16(min(65535, max(0, (65535 * pow(Double(i) / 65535, e)).rounded()))) }
            for y in 0..<height {
                let row = (data + y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    let p = x * 4
                    row[p] = lut[Int(row[p])]
                    row[p + 1] = lut[Int(row[p + 1])]
                    row[p + 2] = lut[Int(row[p + 2])]
                }
            }
        } else {
            var lut = [UInt8](repeating: 0, count: 256)
            for i in 0..<256 { lut[i] = UInt8(min(255, max(0, (255 * pow(Double(i) / 255, e)).rounded()))) }
            for y in 0..<height {
                let row = (data + y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let p = x * 4
                    row[p] = lut[Int(row[p])]
                    row[p + 1] = lut[Int(row[p + 1])]
                    row[p + 2] = lut[Int(row[p + 2])]
                }
            }
        }
    }

    /// A brightened copy of the on-screen preview, using the same curve as the print.
    static func adjusted(_ image: NSImage, _ v: Double) -> NSImage {
        guard v != 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = cg.width, h = cg.height
        let cs = (cg.colorSpace?.model == .rgb ? cg.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let ptr = ctx.data else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        apply(v, data: ptr, bits: 8, width: w, height: h, stride: ctx.bytesPerRow)
        guard let out = ctx.makeImage() else { return image }
        return NSImage(cgImage: out, size: .zero)
    }
}
