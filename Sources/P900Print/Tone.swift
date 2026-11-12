import Foundation
import AppKit
import CoreGraphics

/// The three tone adjustments you can make before printing. All 0 means untouched.
/// Brightness lifts or darkens the midtones, contrast adds or removes an S-curve, saturation scales color strength.
/// Pure black and pure white stay put for brightness and contrast, so nothing clips.
struct Tone: Equatable {
    static let range: ClosedRange<Double> = -50...50

    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0

    var isNeutral: Bool { brightness == 0 && contrast == 0 && saturation == 0 }

    /// Tone curve for one channel value in 0...1.
    func curve(_ x: Double) -> Double {
        var y = x
        if brightness != 0 { y = pow(y, Brightness.exponent(brightness)) }
        if contrast != 0 {
            // x minus a sine bump: keeps 0 and 1 fixed and always rises, so it can't flip tones.
            let k = contrast / 50 * 0.7
            y = y - k * sin(2 * Double.pi * y) / (2 * Double.pi)
        }
        return min(1, max(0, y))
    }

    /// Chroma multiplier. +50 doubles color strength, -50 halves it.
    var saturationFactor: Float { Float(pow(2, saturation / 50)) }

    /// Adjusts an RGBX buffer in place (3 color channels, the 4th is skipped). 8 or 16 bits per channel.
    static func apply(_ t: Tone, data: UnsafeMutableRawPointer, bits: Int, width: Int, height: Int, stride: Int) {
        guard !t.isNeutral else { return }
        let curved = t.brightness != 0 || t.contrast != 0
        let sat: Float? = t.saturation != 0 ? t.saturationFactor : nil
        if bits == 16 {
            var lut = [UInt16]()
            if curved {
                lut = (0..<65536).map { UInt16((65535 * t.curve(Double($0) / 65535)).rounded()) }
            }
            run(UInt16.self, lut: curved ? lut : nil, sat: sat, maxV: 65535,
                data: data, width: width, height: height, stride: stride)
        } else {
            var lut = [UInt8]()
            if curved {
                lut = (0..<256).map { UInt8((255 * t.curve(Double($0) / 255)).rounded()) }
            }
            run(UInt8.self, lut: curved ? lut : nil, sat: sat, maxV: 255,
                data: data, width: width, height: height, stride: stride)
        }
    }

    private static func run<T: FixedWidthInteger & UnsignedInteger>(
        _: T.Type, lut: [T]?, sat: Float?, maxV: Float,
        data: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int
    ) {
        for y in 0..<height {
            let row = (data + y * stride).assumingMemoryBound(to: T.self)
            for x in 0..<width {
                let p = x * 4
                var r = row[p], g = row[p + 1], b = row[p + 2]
                if let lut = lut {
                    r = lut[Int(r)]; g = lut[Int(g)]; b = lut[Int(b)]
                }
                if let f = sat {
                    let rf = Float(r), gf = Float(g), bf = Float(b)
                    let luma = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                    r = T(min(maxV, max(0, luma + (rf - luma) * f)).rounded())
                    g = T(min(maxV, max(0, luma + (gf - luma) * f)).rounded())
                    b = T(min(maxV, max(0, luma + (bf - luma) * f)).rounded())
                }
                row[p] = r; row[p + 1] = g; row[p + 2] = b
            }
        }
    }

    /// An adjusted copy of the on-screen preview, using the same math as the print.
    static func adjusted(_ image: NSImage, _ t: Tone) -> NSImage {
        guard !t.isNeutral,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = cg.width, h = cg.height
        let cs = (cg.colorSpace?.model == .rgb ? cg.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let ptr = ctx.data else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        apply(t, data: ptr, bits: 8, width: w, height: h, stride: ctx.bytesPerRow)
        guard let out = ctx.makeImage() else { return image }
        return NSImage(cgImage: out, size: .zero)
    }
}
