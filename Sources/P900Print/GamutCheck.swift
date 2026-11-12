import Foundation
import AppKit
import CoreGraphics
import CLcms2

/// What the gamut check found for one photo on one paper, measured with Relative Colorimetric.
struct GamutReport {
    let paperName: String
    /// Share of the photo (0...1) that the paper cannot print.
    let outFraction: Double
    /// Average CIEDE2000 shift those colors get when Relative clips them. Around 5 is visible, 10+ is obvious.
    let meanShift: Double
    /// Whether this paper's Perceptual table actually renders those colors differently from Relative.
    let perceptualDiffers: Bool

    init(paperName: String, stats: P900GamutStats) {
        self.paperName = paperName
        let total = max(Double(stats.total), 1)
        self.outFraction = Double(stats.outCount) / total
        self.meanShift = max(stats.meanDeltaE, 0)
        self.perceptualDiffers = stats.perceptualShift >= 1.0
    }
}

enum GamutCheck {
    /// Scans the photo against the paper profile. The photo is shrunk to at most maxSide pixels on its long edge,
    /// which is plenty for a warning and keeps it quick.
    static func scan(image: NSImage,
                     paperURL: URL,
                     intent: Intent,
                     blackPoint: Bool,
                     wantMask: Bool,
                     maxSide: Int) throws -> (stats: P900GamutStats, mask: NSImage?) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PipelineError.failed("Could not read the preview image.")
        }

        let longSide = max(cg.width, cg.height)
        let factor = min(1.0, Double(maxSide) / Double(max(longSide, 1)))
        let w = max(1, Int((Double(cg.width) * factor).rounded()))
        let h = max(1, Int((Double(cg.height) * factor).rounded()))

        // Source profile: the image's own, or sRGB if it has none (same rule the print uses).
        let workingCS: CGColorSpace
        let iccData: Data
        if let cs = cg.colorSpace, cs.model == .rgb, let cf = cs.copyICCData() {
            workingCS = cs
            iccData = cf as Data
        } else {
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB), let cf = srgb.copyICCData() else {
                throw PipelineError.failed("Could not create a fallback sRGB profile.")
            }
            workingCS = srgb
            iccData = cf as Data
        }

        func makeContext(bits: Int) -> CGContext? {
            var info = CGImageAlphaInfo.noneSkipLast.rawValue
            if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
            return CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: 0,
                             space: workingCS, bitmapInfo: info)
        }
        var bits = 16
        var ctxOpt = makeContext(bits: 16)
        if ctxOpt == nil {
            bits = 8
            ctxOpt = makeContext(bits: 8)
        }
        guard let ctx = ctxOpt, let srcPtr = ctx.data else {
            throw PipelineError.failed("Could not allocate the gamut check buffer.")
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var stats = P900GamutStats()
        var maskData = [UInt8](repeating: 0, count: wantMask ? w * h * 4 : 4)
        var errBuf = [CChar](repeating: 0, count: 256)
        let errLen = errBuf.count
        let rowBytes = ctx.bytesPerRow
        let rc: Int32 = iccData.withUnsafeBytes { raw in
            paperURL.path.withCString { path in
                maskData.withUnsafeMutableBufferPointer { mp in
                    p900_gamut_scan(raw.baseAddress, UInt32(raw.count), path,
                                    Int32(intent.cmsCode), blackPoint ? 1 : 0,
                                    srcPtr, Int32(bits), rowBytes,
                                    UInt32(w), UInt32(h),
                                    wantMask ? mp.baseAddress : nil, w * 4,
                                    &stats, &errBuf, errLen)
                }
            }
        }
        if rc != 0 {
            throw PipelineError.failed(String(cString: errBuf))
        }

        var maskImage: NSImage?
        if wantMask {
            let data = Data(maskData)
            if let provider = CGDataProvider(data: data as CFData),
               let cgMask = CGImage(width: w, height: h,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent) {
                maskImage = NSImage(cgImage: cgMask, size: .zero)
            }
        }
        return (stats, maskImage)
    }
}

/// Turns a gamut report into a plain-language suggestion about the rendering intent.
enum GamutAdvice {
    struct Tip {
        let text: String
        /// The intent the button would switch to, if there is a good one.
        let suggest: Intent?
    }

    static func tip(report r: GamutReport, current: Intent) -> Tip? {
        let pct = r.outFraction * 100
        let pctText = pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
        let shift = Int(r.meanShift.rounded())
        // Lots of out-of-gamut color, or a smaller amount that gets clipped hard.
        let heavy = pct >= 2.0 || (pct >= 0.5 && r.meanShift >= 9)
        let light = pct < 0.5

        switch current {
        case .relative:
            guard heavy else { return nil }
            if r.perceptualDiffers {
                return Tip(text: "About \(pctText) of this photo is outside what \(r.paperName) can print. Relative clips those colors to the nearest printable color (average shift \(shift)), which can flatten detail in saturated areas. Perceptual squeezes everything in instead. Compare both with Preview PDF.",
                           suggest: .perceptual)
            }
            return Tip(text: "About \(pctText) of this photo is outside what \(r.paperName) can print, but this paper's Perceptual table renders those colors the same as Relative, so switching won't help. If saturated areas look flat, ease their saturation in Photoshop.",
                       suggest: nil)

        case .perceptual:
            guard light else { return nil }
            return Tip(text: "Almost everything here fits \(r.paperName) (\(pctText) is outside). Perceptual shifts all the colors slightly to make room it doesn't need. Relative keeps them exact.",
                       suggest: .relative)

        case .saturation:
            let target: Intent = (heavy && r.perceptualDiffers) ? .perceptual : .relative
            return Tip(text: "Saturation boosts colors and is meant for graphics. For a photograph, use \(target.label).",
                       suggest: target)

        case .absolute:
            return Tip(text: "Absolute Colorimetric is for proofing. It prints a little ink in the highlights to imitate another paper's white. For a finished print, Relative is the usual choice.",
                       suggest: .relative)
        }
    }
}
