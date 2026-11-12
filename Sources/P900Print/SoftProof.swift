import Foundation
import AppKit
import CoreGraphics
import CLcms2

/// Renders the photo the way it will look on the chosen paper, for showing on screen.
/// It runs the same photo-to-paper conversion the print uses, then shows those paper values on the display.
enum SoftProof {
    static func render(image: NSImage,
                       paperURL: URL,
                       intent: Intent,
                       blackPoint: Bool,
                       simulatePaper: Bool,
                       maxSide: Int) throws -> NSImage {
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
            throw PipelineError.failed("Could not allocate the soft proof buffer.")
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var outData = [UInt8](repeating: 0, count: w * h * 4)
        var errBuf = [CChar](repeating: 0, count: 256)
        let errLen = errBuf.count
        let rowBytes = ctx.bytesPerRow
        let rc: Int32 = iccData.withUnsafeBytes { raw in
            paperURL.path.withCString { path in
                outData.withUnsafeMutableBufferPointer { op in
                    p900_softproof(raw.baseAddress, UInt32(raw.count), path,
                                   Int32(intent.cmsCode), blackPoint ? 1 : 0, simulatePaper ? 1 : 0,
                                   srcPtr, Int32(bits), rowBytes,
                                   UInt32(w), UInt32(h),
                                   op.baseAddress, w * 4,
                                   &errBuf, errLen)
                }
            }
        }
        if rc != 0 {
            throw PipelineError.failed(String(cString: errBuf))
        }

        // The result is in sRGB, which macOS then color-manages to whatever display you are using.
        guard let provider = CGDataProvider(data: Data(outData) as CFData),
              let srgbOut = CGColorSpace(name: CGColorSpace.sRGB),
              let outImage = CGImage(width: w, height: h,
                                     bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: w * 4, space: srgbOut,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil,
                                     shouldInterpolate: true, intent: .defaultIntent) else {
            throw PipelineError.failed("Could not build the soft proof image.")
        }
        return NSImage(cgImage: outImage, size: .zero)
    }
}
