import Foundation
import AppKit
import CoreGraphics

struct PrintJob {
    let imageURL: URL
    let pixels: CGSize
    let layout: LayoutResult
    let sheet: SheetSize
    let paper: PaperPreset
    let intent: Intent
    let blackPoint: Bool
    let tagWithPaperProfile: Bool
    let queue: String
    let copies: Int
    let frontFeed: Bool
    let overcoat: Bool
    let glossSmooth: Bool
    let bottomEdge: Bool
    let highSpeed: Bool
    let tone: Tone

    /// Runs the whole job. Returns a status message for the log.
    func run(dryRun: Bool) throws -> String {
        var lines: [String] = []

        let aspect = Double(pixels.width / max(pixels.height, 1))
        let wantW = Int((layout.rect.width / 72 * P900.targetPPI).rounded())
        let tw = max(16, min(Int(pixels.width), wantW))
        let th = max(16, Int((Double(tw) / aspect).rounded()))
        if tw < wantW {
            lines.append("Source is smaller than \(Int(P900.targetPPI)) ppi at this size, left at native resolution.")
        } else {
            lines.append("Resampled to \(tw) x \(th) px (\(Int(P900.targetPPI)) ppi).")
        }

        let converted = try ColorPipeline.convert(url: imageURL,
                                                  targetW: tw, targetH: th,
                                                  paperProfile: paper.url,
                                                  intent: intent,
                                                  blackPoint: blackPoint,
                                                  tagWithPaperProfile: tagWithPaperProfile,
                                                  tone: tone)
        lines.append(contentsOf: converted.notes)
        var toneNotes: [String] = []
        if tone.brightness != 0 { toneNotes.append(String(format: "brightness %+d", Int(tone.brightness.rounded()))) }
        if tone.contrast != 0 { toneNotes.append(String(format: "contrast %+d", Int(tone.contrast.rounded()))) }
        if tone.saturation != 0 { toneNotes.append(String(format: "saturation %+d", Int(tone.saturation.rounded()))) }
        if !toneNotes.isEmpty { lines.append("Adjusted: " + toneNotes.joined(separator: ", ") + ".") }
        lines.append("Converted to \(paper.name), \(intent.label)\(blackPoint ? ", black point compensation" : "").")

        let pdf = try PDFWriter.write(image: converted.image, layout: layout, title: imageURL.displayName)

        if dryRun {
            DispatchQueue.main.async { NSWorkspace.shared.open(pdf) }
            lines.append("PDF opened in Preview (nothing was sent to the printer).")
            return lines.joined(separator: "\n")
        }

        let result = try Spooler.submit(pdf: pdf, queue: queue, sheet: sheet, bleed: layout.bleed,
                                        mediaCode: paper.mediaCode, copies: copies,
                                        frontFeed: frontFeed, overcoat: overcoat,
                                        glossSmooth: glossSmooth, bottomEdge: bottomEdge, highSpeed: highSpeed,
                                        title: imageURL.displayName)
        lines.append(result)
        return lines.joined(separator: "\n")
    }
}

enum PDFWriter {
    static func write(image: CGImage, layout: LayoutResult, title: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("P900Print", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let safe = title.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(safe)-\(stamp).pdf")

        var box = CGRect(x: 0, y: 0, width: layout.canvasW, height: layout.canvasH)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw PipelineError.failed("Could not create the PDF.")
        }
        ctx.beginPDFPage(nil)
        if layout.landscape {
            // The sheet is always fed portrait, so a landscape page is the portrait page turned 90 degrees.
            ctx.translateBy(x: CGFloat(layout.canvasW), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: layout.rect)

        if layout.cropMarks && !layout.bleed {
            // Stroke in the same color space as the image so the marks take the same path to the printer.
            if let cs = image.colorSpace, cs.model == .rgb {
                ctx.setStrokeColorSpace(cs)
                ctx.setStrokeColor([0, 0, 0, 1])
            } else {
                ctx.setStrokeColor(gray: 0, alpha: 1)
            }
            ctx.setLineWidth(0.5)
            for (a, b) in CropMarks.segments(for: layout.trim) {
                ctx.move(to: a)
                ctx.addLine(to: b)
            }
            ctx.strokePath()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }
}

enum Spooler {
    enum Preflight { case ok, offline(String), queued(Int) }

    /// Looks at the print queue (local only, never touches the USB link) before anything is sent.
    static func preflight(queue: String) -> Preflight {
        let status = (InkReader.shell("/usr/bin/lpstat", ["-p", queue]) ?? "").lowercased()
        if status.contains("offline") || status.contains("disabled") || status.contains("paused") {
            return .offline("The printer looks offline or paused, so nothing was sent. Check that it is on and connected to the network (or USB), then try again.")
        }
        let jobs = (InkReader.shell("/usr/bin/lpstat", ["-o", queue]) ?? "")
            .split(separator: "\n").filter { !$0.isEmpty }.count
        return jobs > 0 ? .queued(jobs) : .ok
    }

    /// Finds the CUPS queue to print to. If the saved name no longer exists (for example after the
    /// printer was re-added over the network), falls back to the first queue with "P900" in its name.
    static func resolveQueue(_ preferred: String) -> String? {
        let out = InkReader.shell("/usr/bin/lpstat", ["-p"]) ?? ""
        var names: [String] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "printer" { names.append(String(parts[1])) }
        }
        if names.contains(preferred) { return preferred }
        return names.first { $0.lowercased().contains("p900") }
    }

    /// Sends the PDF to CUPS with the P900 driver options baked in.
    static func submit(pdf: URL, queue: String, sheet: SheetSize, bleed: Bool,
                       mediaCode: String, copies: Int,
                       frontFeed: Bool, overcoat: Bool, glossSmooth: Bool, bottomEdge: Bool, highSpeed: Bool,
                       title: String) throws -> String {
        // Front - Thick is the front feed path for thick fine art paper (Epson: paper over 0.5 mm).
        let pageSize: String
        let source: String
        if frontFeed {
            pageSize = sheet.ppdName + (bleed ? ".SheetNMgnRet" : ".SheetMax")
            source = bleed ? "41" : "31"   // 41 = Front - Thick, Borderless Retain Size; 31 = Front - Thick
        } else {
            pageSize = bleed ? sheet.ppdName + ".4SideNMgnRet" : sheet.ppdName
            source = bleed ? "40" : "2"    // 40 = Sheet, Borderless Retain Size; 2 = Sheet
        }
        var options: [(String, String)] = [
            ("PageSize", pageSize),
            ("EPIJ_Size", sheet.epijSize),
            ("EPIJ_PSrc", source),
            ("EPIJ_Medi", mediaCode),
            ("EPIJ_Ink_", "1"),                  // EPSON PrecisionDot
            ("EPIJ_Mode", "3"),                  // Advanced
            ("EPIJ_CMat", "3"),                  // Off (No Color Management)
            ("EPIJ_PrntMode", "4"),              // Max Quality
            ("EPIJ_Qual", "52"),                 // SuperPhoto 5760 dpi
            ("EPIJ_Bi_D", highSpeed ? "1" : "0"), // High Speed (bidirectional)
            ("EPIJ_FDet", "1"),                  // Finest Detail on
            ("print-scaling", "none"),
        ]

        if overcoat { options.append(("EPIJ_OvCt", "1")) }       // Black Enhance Overcoat
        if glossSmooth { options.append(("EPIJ_AnGl", "1")) }    // Gloss Smoothing
        if bottomEdge { options.append(("EPIJ_BEQP", "1")) }     // Bottom Edge Print Quality Priority

        var args = ["-d", queue, "-n", String(max(1, copies)), "-t", title]
        for (k, v) in options {
            args.append("-o")
            args.append("\(k)=\(v)")
        }
        args.append(pdf.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let cmd = "lp " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        if p.terminationStatus != 0 {
            throw PipelineError.failed("lp failed: \(text)\n\(cmd)")
        }
        return "Sent to \(queue): \(text)\n\(cmd)"
    }
}
