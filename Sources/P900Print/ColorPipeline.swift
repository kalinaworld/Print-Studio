import Foundation
import CoreGraphics
import ImageIO
import CLcms2

enum PipelineError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let m): return m
        }
    }
}

enum ColorPipeline {
    /// Resamples the image to targetW x targetH, converts it from its own profile to the
    /// paper profile (with the chosen intent and black point compensation), and returns
    /// an 8-bit image ready to embed in the PDF.
    static func convert(url: URL,
                        targetW: Int,
                        targetH: Int,
                        paperProfile: URL,
                        intent: Intent,
                        blackPoint: Bool,
                        tagWithPaperProfile: Bool,
                        tone: Tone = Tone()) throws -> (image: CGImage, notes: [String]) {
        var notes: [String] = []

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw PipelineError.failed("Could not read \(url.lastPathComponent).")
        }

        // Source profile: the image's own, or sRGB if it has none (or is not RGB).
        let workingCS: CGColorSpace
        let iccData: Data
        if let cs = full.colorSpace, cs.model == .rgb, let cf = cs.copyICCData() {
            workingCS = cs
            iccData = cf as Data
        } else {
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB), let cf = srgb.copyICCData() else {
                throw PipelineError.failed("Could not create a fallback sRGB profile.")
            }
            workingCS = srgb
            iccData = cf as Data
            notes.append("Image has no RGB profile, treated as sRGB.")
        }

        // Resample in the source space, keeping 16 bits when macOS allows it.
        func makeContext(bits: Int) -> CGContext? {
            var info = CGImageAlphaInfo.noneSkipLast.rawValue
            if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
            return CGContext(data: nil, width: targetW, height: targetH,
                             bitsPerComponent: bits, bytesPerRow: 0,
                             space: workingCS, bitmapInfo: info)
        }
        var bits = 16
        var ctxOpt = makeContext(bits: 16)
        if ctxOpt == nil {
            bits = 8
            ctxOpt = makeContext(bits: 8)
            notes.append("16-bit working buffer was not available, used 8-bit.")
        }
        guard let ctx = ctxOpt, let srcPtr = ctx.data else {
            throw PipelineError.failed("Could not allocate the image buffer (\(targetW) x \(targetH)).")
        }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        Tone.apply(tone, data: srcPtr, bits: bits, width: targetW, height: targetH, stride: ctx.bytesPerRow)

        // Convert to the paper profile.
        let srcStride = ctx.bytesPerRow
        let dstStride = targetW * 4
        guard let out = NSMutableData(length: dstStride * targetH) else {
            throw PipelineError.failed("Could not allocate the output buffer.")
        }
        var errBuf = [CChar](repeating: 0, count: 256)
        let errLen = errBuf.count
        let rc: Int32 = iccData.withUnsafeBytes { raw in
            paperProfile.path.withCString { path in
                p900_convert(raw.baseAddress, UInt32(raw.count), path,
                             Int32(intent.cmsCode), blackPoint ? 1 : 0,
                             srcPtr, Int32(bits), srcStride,
                             out.mutableBytes, dstStride,
                             UInt32(targetW), UInt32(targetH),
                             &errBuf, errLen)
            }
        }
        if rc != 0 {
            throw PipelineError.failed(String(cString: errBuf))
        }

        // Tag the result so the PDF knows these numbers are already in paper space.
        var destCS = CGColorSpaceCreateDeviceRGB()
        if tagWithPaperProfile {
            if let d = try? Data(contentsOf: paperProfile), let cs = CGColorSpace(iccData: d as CFData) {
                destCS = cs
            } else {
                notes.append("macOS would not accept the paper profile as a PDF color space, embedded as Device RGB.")
            }
        }

        guard let provider = CGDataProvider(data: out as CFData),
              let image = CGImage(width: targetW, height: targetH,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: dstStride, space: destCS,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw PipelineError.failed("Could not build the converted image.")
        }
        return (image, notes)
    }
}
