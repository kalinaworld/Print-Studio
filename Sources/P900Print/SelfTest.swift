import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Command line self test used by check_color_pipeline.py.
/// Builds a patch chart, runs it through the real color pipeline, writes two PDFs
/// (paper profile tagged and untagged) plus the pixel values the printer filters should receive.
enum SelfTest {
    static func run(args: [String]) -> Int32 {
        guard let idx = args.firstIndex(of: "--selftest"), args.count > idx + 1 else {
            fputs("usage: P900Print --selftest <outdir> [profile file name]\n", stderr)
            return 2
        }
        let outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        let wanted = args.count > idx + 2 ? args[idx + 2] : "cifa_p900_ragphot310_m_bk.icc"
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            return try execute(outDir: outDir, wanted: wanted)
        } catch {
            fputs("selftest failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func execute(outDir: URL, wanted: String) throws -> Int32 {
        guard let profile = ProfileScanner.printerProfiles().first(where: { $0.lastPathComponent == wanted }) else {
            fputs("Paper profile not found: \(wanted)\n", stderr)
            return 3
        }

        let W = 900
        let H = 1200
        let cols = 2
        let rows = 3
        let patches: [(String, [Int])] = [
            ("red", [255, 0, 0]),
            ("green", [0, 255, 0]),
            ("blue", [0, 0, 255]),
            ("gray50", [128, 128, 128]),
            ("skin", [200, 150, 120]),
            ("shadow", [30, 40, 60]),
        ]

        // 1. Patch chart in sRGB, saved as a TIFF like a real file.
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PipelineError.failed("Could not create the test chart.")
        }
        ctx.setFillColorSpace(srgb)
        ctx.setFillColor([1, 1, 1, 1])
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let cw = CGFloat(W) / CGFloat(cols)
        let ch = CGFloat(H) / CGFloat(rows)
        for (i, p) in patches.enumerated() {
            let col = i % cols
            let row = i / cols
            ctx.setFillColor([CGFloat(p.1[0]) / 255, CGFloat(p.1[1]) / 255, CGFloat(p.1[2]) / 255, 1])
            ctx.fill(CGRect(x: CGFloat(col) * cw, y: CGFloat(H) - CGFloat(row + 1) * ch, width: cw, height: ch))
        }
        guard let chart = ctx.makeImage() else { throw PipelineError.failed("Could not render the test chart.") }
        let tiff = outDir.appendingPathComponent("chart.tif")
        guard let dest = CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw PipelineError.failed("Could not create chart.tif.")
        }
        CGImageDestinationAddImage(dest, chart, nil)
        guard CGImageDestinationFinalize(dest) else { throw PipelineError.failed("Could not write chart.tif.") }

        // 2. Same layout the app would use for a portrait image on Letter.
        let sheet = SheetSize.all.first(where: { $0.id == "letter" }) ?? SheetSize.all[0]
        let layout = LayoutEngine.compute(sheet: sheet, mode: .fit, orientation: .portrait,
                                          pixels: CGSize(width: W, height: H), dpi: 300,
                                          borderInches: 0, customScale: 1,
                                          hAlign: .center, vAlign: .middle, half: .top, cropMarks: false)

        // 3. Convert through the real pipeline, once tagged and once untagged.
        var pdfNames: [String: String] = [:]
        var patchJSON: [[String: Any]] = []
        var notes: [String] = []
        for tag in [true, false] {
            let r = try ColorPipeline.convert(url: tiff, targetW: W, targetH: H, paperProfile: profile,
                                              intent: .relative, blackPoint: true, tagWithPaperProfile: tag)
            notes.append(contentsOf: r.notes.map { (tag ? "tagged: " : "untagged: ") + $0 })
            let tmp = try PDFWriter.write(image: r.image, layout: layout, title: tag ? "selftest-tagged" : "selftest-device")
            let name = tag ? "test-tagged.pdf" : "test-device.pdf"
            let dst = outDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: tmp, to: dst)
            pdfNames[tag ? "tagged" : "device"] = name

            if patchJSON.isEmpty {
                for (i, p) in patches.enumerated() {
                    let col = i % cols
                    let row = i / cols
                    let x = Int((Double(col) + 0.5) * Double(W) / Double(cols))
                    let y = Int((Double(row) + 0.5) * Double(H) / Double(rows))
                    patchJSON.append([
                        "name": p.0, "col": col, "row": row,
                        "src": p.1,
                        "expected": sample(r.image, x: x, y: y),
                    ])
                }
            }
        }

        let rect = layout.rect
        let json: [String: Any] = [
            "profile": wanted,
            "cols": cols,
            "rows": rows,
            "pdfs": pdfNames,
            "page": [
                "w": layout.pageW,
                "h": layout.pageH,
                "rect": [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
            ],
            "patches": patchJSON,
            "notes": notes,
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent("expected.json"))
        print("selftest ok")
        return 0
    }

    private static func sample(_ img: CGImage, x: Int, y: Int) -> [Int] {
        guard let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return [0, 0, 0] }
        let o = y * img.bytesPerRow + x * 4
        return [Int(ptr[o]), Int(ptr[o + 1]), Int(ptr[o + 2])]
    }
}
