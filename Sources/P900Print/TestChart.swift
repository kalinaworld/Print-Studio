import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A test image for comparing driver settings on paper: color patches, a gray step wedge,
/// smooth gradients (banding) and fine line patterns (detail). 8.5 x 11 in at 300 ppi, sRGB.
enum TestChart {
    static let W = 2550
    static let H = 3300

    static func make() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("P900Print", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("P900 Test Chart.tif")

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PipelineError.failed("Could not create the test chart.")
        }
        ctx.setFillColorSpace(srgb)
        func fill(_ rgb: [Int], _ r: CGRect) {
            // Drawing text switches the context to a gray color space, so set sRGB every time.
            ctx.setFillColorSpace(srgb)
            ctx.setFillColor([CGFloat(rgb[0]) / 255, CGFloat(rgb[1]) / 255, CGFloat(rgb[2]) / 255, 1])
            ctx.fill(r)
        }
        func gray(_ v: Int, _ r: CGRect) { fill([v, v, v], r) }
        func label(_ s: String, x: CGFloat, y: CGFloat) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .regular),
                .foregroundColor: NSColor.black,
            ]
            NSAttributedString(string: s, attributes: attrs).draw(at: NSPoint(x: x, y: y))
            NSGraphicsContext.restoreGraphicsState()
        }

        gray(255, CGRect(x: 0, y: 0, width: W, height: H))
        let left: CGFloat = 150
        let usable = CGFloat(W) - 2 * left
        var top = CGFloat(H) - 130   // y of the top edge of the next block

        label("P900 TEST CHART  8.5 x 11 in  300 ppi  sRGB", x: left, y: top - 20)
        top -= 90

        // 1. Color patches
        let colors: [[Int]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [0, 255, 255], [255, 0, 255],
                               [255, 255, 0], [200, 150, 120], [128, 128, 128], [30, 40, 60]]
        let pw = usable / CGFloat(colors.count)
        let ph: CGFloat = 380
        for (i, c) in colors.enumerated() {
            fill(c, CGRect(x: left + CGFloat(i) * pw, y: top - ph, width: pw, height: ph))
        }
        top -= ph
        label("colors: R G B C M Y skin 50% shadow", x: left, y: top - 55)
        top -= 120

        // 2. Gray step wedge, 21 steps from white to black
        let steps = 21
        let sw = usable / CGFloat(steps)
        let sh: CGFloat = 260
        for i in 0..<steps {
            let v = 255 - Int((Double(i) / Double(steps - 1) * 255).rounded())
            gray(v, CGRect(x: left + CGFloat(i) * sw, y: top - sh, width: sw, height: sh))
        }
        top -= sh
        label("gray steps, white to black (look for the first two steps at each end)", x: left, y: top - 55)
        top -= 120

        // 3. Smooth gradients: full range, shadows, highlights
        func gradient(_ lo: Int, _ hi: Int, height: CGFloat, name: String) {
            let n = Int(usable)
            for x in 0..<n {
                let t = Double(x) / Double(n - 1)
                let v = lo + Int((Double(hi - lo) * t).rounded())
                gray(v, CGRect(x: left + CGFloat(x), y: top - height, width: 1, height: height))
            }
            top -= height
            label(name, x: left, y: top - 55)
            top -= 120
        }
        gradient(0, 255, height: 200, name: "gradient: full range")
        gradient(0, 70, height: 200, name: "gradient: shadows (banding shows here)")
        gradient(190, 255, height: 200, name: "gradient: highlights")

        // 3b. Color ramps from white to each full color (smooth saturation, banding and color casts)
        let ramps: [[Int]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [0, 255, 255], [255, 0, 255], [255, 255, 0]]
        let n = Int(usable)
        let rh: CGFloat = 70
        for c in ramps {
            for x in 0..<n {
                let t = Double(x) / Double(n - 1)
                let v = (0..<3).map { 255 + Int((Double(c[$0] - 255) * t).rounded()) }
                fill(v, CGRect(x: left + CGFloat(x), y: top - rh, width: 1, height: rh))
            }
            top -= rh + 8
        }
        label("color ramps: white to R G B C M Y", x: left, y: top - 47)
        top -= 120

        // 4. Fine line patterns, vertical and horizontal, at several widths
        let widths = [2, 3, 4, 6]
        let bw = (usable - CGFloat(widths.count - 1) * 30) / CGFloat(widths.count)
        let bh: CGFloat = 300
        for (i, lw) in widths.enumerated() {
            let x0 = left + CGFloat(i) * (bw + 30)
            gray(255, CGRect(x: x0, y: top - bh, width: bw, height: bh))
            var x = x0
            while x < x0 + bw / 2 - CGFloat(lw) {
                gray(0, CGRect(x: x, y: top - bh, width: CGFloat(lw), height: bh))
                x += CGFloat(lw * 2)
            }
            var y = top - bh
            while y < top - CGFloat(lw) {
                gray(0, CGRect(x: x0 + bw / 2, y: y, width: bw / 2, height: CGFloat(lw)))
                y += CGFloat(lw * 2)
            }
        }
        top -= bh
        label("fine lines: 2 3 4 6 px (vertical left, horizontal right)", x: left, y: top - 55)

        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw PipelineError.failed("Could not write the test chart.")
        }
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PipelineError.failed("Could not write the test chart.") }
        return url
    }
}
