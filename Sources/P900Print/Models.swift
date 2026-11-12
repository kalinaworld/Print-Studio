import Foundation
import CoreGraphics

// MARK: - Epson P900 driver constants (taken from the installed PPD)

struct MediaType: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

enum P900 {
    static let defaultQueue = "EPSON_SC_P900_Series"

    /// EPIJ_Medi codes from the P900 PPD.
    static let mediaTypes: [MediaType] = [
        MediaType(code: "183", name: "Fine Art Matte"),
        MediaType(code: "27", name: "Ultra Premium Photo Paper Luster"),
        MediaType(code: "157", name: "Baryta"),
        MediaType(code: "13", name: "Premium Photo Paper Glossy"),
        MediaType(code: "15", name: "Premium Photo Paper Semigloss"),
        MediaType(code: "145", name: "Photo Paper Glossy"),
        MediaType(code: "53", name: "Velvet Fine Art Paper"),
        MediaType(code: "88", name: "UltraSmooth Fine Art Paper"),
        MediaType(code: "17", name: "Watercolor Paper Radiant White"),
        MediaType(code: "181", name: "Washi"),
        MediaType(code: "14", name: "Ultra Premium Presentation Paper Matte"),
        MediaType(code: "2", name: "Presentation Paper Matte"),
        MediaType(code: "153", name: "Canvas Satin"),
        MediaType(code: "155", name: "Canvas Matte"),
        MediaType(code: "106", name: "Proofing Paper White Semimatte"),
    ]

    static func mediaName(_ code: String) -> String {
        mediaTypes.first(where: { $0.code == code })?.name ?? "Media \(code)"
    }

    /// Pixels per inch the image is resampled to before color conversion.
    static let targetPPI: Double = 360
}

// MARK: - Sheet sizes

struct SheetSize: Identifiable {
    let id: String
    let label: String
    let ppdName: String     // PageSize value in the PPD
    let epijSize: String    // EPIJ_Size value
    let paperW: Double      // points, portrait
    let paperH: Double
    let margin: Double      // driver margin on every side, points

    /// "Borderless, Retain Size" pages are 14 pt larger than the paper on every side.
    static let bleedExtra: Double = 14

    var bleedW: Double { paperW + 2 * SheetSize.bleedExtra }
    var bleedH: Double { paperH + 2 * SheetSize.bleedExtra }

    static let all: [SheetSize] = [
        SheetSize(id: "letter", label: "8.5 × 11", ppdName: "Letter", epijSize: "4",
                  paperW: 612, paperH: 792, margin: 8.4),
        SheetSize(id: "13x19", label: "13 × 19", ppdName: "EP13x19", epijSize: "10",
                  paperW: 932.6, paperH: 1369.2, margin: 8.4),
        SheetSize(id: "17x22", label: "17 × 22", ppdName: "EPUS_C", epijSize: "37",
                  paperW: 1224, paperH: 1584, margin: 8.4),
    ]
}

// MARK: - Simple enums

enum LayoutMode: String, CaseIterable, Identifiable {
    case fit, bleed, custom, half
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "Fit"
        case .bleed: return "Full bleed"
        case .custom: return "Custom"
        case .half: return "Half sheet"
        }
    }
}

enum PaperOrientation: String, CaseIterable, Identifiable {
    case auto, portrait, landscape
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }
}

enum Intent: String, CaseIterable, Identifiable {
    case relative, perceptual, saturation, absolute
    var id: String { rawValue }
    var label: String {
        switch self {
        case .relative: return "Relative Colorimetric"
        case .perceptual: return "Perceptual"
        case .saturation: return "Saturation"
        case .absolute: return "Absolute Colorimetric"
        }
    }
    /// Little CMS intent codes.
    var cmsCode: Int {
        switch self {
        case .perceptual: return 0
        case .relative: return 1
        case .saturation: return 2
        case .absolute: return 3
        }
    }
}

enum HAlign: String, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var label: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }
    var factor: Double {
        switch self {
        case .left: return 0
        case .center: return 0.5
        case .right: return 1
        }
    }
}

enum VAlign: String, CaseIterable, Identifiable {
    case top, middle, bottom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .top: return "Top"
        case .middle: return "Middle"
        case .bottom: return "Bottom"
        }
    }
    /// Page coordinates have the origin at the bottom, so top is 1.
    var factor: Double {
        switch self {
        case .top: return 1
        case .middle: return 0.5
        case .bottom: return 0
        }
    }
}

enum HalfPosition: String, CaseIterable, Identifiable {
    case top, bottom, left, right
    var id: String { rawValue }
    var label: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

// MARK: - Crop marks

enum CropMarks {
    static let offset: Double = 4.5     // gap between the image corner and the mark, points
    static let length: Double = 18      // length of each mark, points
    static var extent: Double { offset + length }

    /// Eight short line segments, two at every corner of the image, outside the image.
    static func segments(for r: CGRect) -> [(CGPoint, CGPoint)] {
        let o = CGFloat(offset)
        let l = CGFloat(length)
        var segs: [(CGPoint, CGPoint)] = []
        for (cx, dx) in [(r.minX, CGFloat(-1)), (r.maxX, CGFloat(1))] {
            for (cy, dy) in [(r.minY, CGFloat(-1)), (r.maxY, CGFloat(1))] {
                segs.append((CGPoint(x: cx + dx * o, y: cy), CGPoint(x: cx + dx * (o + l), y: cy)))
                segs.append((CGPoint(x: cx, y: cy + dy * o), CGPoint(x: cx, y: cy + dy * (o + l))))
            }
        }
        return segs
    }
}

// MARK: - Layout

struct LayoutResult {
    var canvasW: Double     // physical page sent to the printer (portrait), points
    var canvasH: Double
    var pageW: Double       // the page as you hold it (swapped when landscape)
    var pageH: Double
    var landscape: Bool
    var bleed: Bool
    var margin: Double
    var rect: CGRect        // where the image goes, in page coordinates, origin bottom-left
    var trim: CGRect        // the image plus its white border; crop marks sit at the corners of this
    var otherCell: CGRect?  // the free half in half-sheet mode
    var cropMarks: Bool
}

enum LayoutEngine {
    /// Gap kept between the two prints in half-sheet mode, points.
    /// Largest white border around the photo, inches.
    static let maxBorderInches: Double = 0.5
    static let halfGap: Double = 36            // 0.5 in
    static let halfGapWithMarks: Double = 54   // 0.75 in, so both prints' marks fit between them

    static func compute(sheet: SheetSize,
                        mode: LayoutMode,
                        orientation: PaperOrientation,
                        pixels: CGSize,
                        dpi: Double,
                        borderInches: Double,
                        customScale: Double,
                        hAlign: HAlign,
                        vAlign: VAlign,
                        half: HalfPosition,
                        cropMarks: Bool) -> LayoutResult {
        let pw = max(Double(pixels.width), 1)
        let ph = max(Double(pixels.height), 1)
        let aspect = pw / ph
        let useDPI = dpi > 1 ? dpi : 300

        let landscape: Bool
        switch orientation {
        case .auto: landscape = (mode == .half) ? false : (pw >= ph)
        case .portrait: landscape = false
        case .landscape: landscape = true
        }

        let bleed = (mode == .bleed)
        let marks = cropMarks && !bleed
        let markInset = marks ? CropMarks.extent : 0

        let canvasW = bleed ? sheet.bleedW : sheet.paperW
        let canvasH = bleed ? sheet.bleedH : sheet.paperH
        let pageW = landscape ? canvasH : canvasW
        let pageH = landscape ? canvasW : canvasH

        var rect: CGRect
        var other: CGRect? = nil
        let b = bleed ? 0 : min(max(borderInches, 0), maxBorderInches) * 72   // white border around the photo, points

        switch mode {
        case .fit:
            let m = sheet.margin + markInset + b
            let avail = CGRect(x: m, y: m, width: max(pageW - 2 * m, 1), height: max(pageH - 2 * m, 1))
            var w = Double(avail.width)
            var h = w / aspect
            if h > Double(avail.height) {
                h = Double(avail.height)
                w = h * aspect
            }
            rect = place(w, h, in: avail, hAlign: hAlign, vAlign: vAlign)

        case .bleed:
            var w = pageW
            var h = w / aspect
            if h < pageH {
                h = pageH
                w = h * aspect
            }
            rect = CGRect(x: (pageW - w) / 2, y: (pageH - h) / 2, width: w, height: h)

        case .custom:
            let w = pw / useDPI * 72 * max(customScale, 0.01)
            let h = ph / useDPI * 72 * max(customScale, 0.01)
            let m = sheet.margin + markInset
            let avail = CGRect(x: m, y: m, width: pageW - 2 * m, height: pageH - 2 * m)
            let t = place(w + 2 * b, h + 2 * b, in: avail, hAlign: hAlign, vAlign: vAlign)
            rect = t.insetBy(dx: CGFloat(b), dy: CGFloat(b))

        case .half:
            let gap = marks ? halfGapWithMarks : halfGap
            let m = sheet.margin + markInset
            let area = CGRect(x: m, y: m, width: max(pageW - 2 * m, 1), height: max(pageH - 2 * m, 1))
            let cellH = max((Double(area.height) - gap) / 2, 1)
            let cellW = max((Double(area.width) - gap) / 2, 1)
            let cell: CGRect
            var ha = HAlign.center
            var va = VAlign.middle
            switch half {
            case .top:
                cell = CGRect(x: area.minX, y: area.maxY - cellH, width: area.width, height: cellH)
                other = CGRect(x: area.minX, y: area.minY, width: area.width, height: cellH)
                va = .top
            case .bottom:
                cell = CGRect(x: area.minX, y: area.minY, width: area.width, height: cellH)
                other = CGRect(x: area.minX, y: area.maxY - cellH, width: area.width, height: cellH)
                va = .bottom
            case .left:
                cell = CGRect(x: area.minX, y: area.minY, width: cellW, height: area.height)
                other = CGRect(x: area.maxX - cellW, y: area.minY, width: cellW, height: area.height)
                ha = .left
            case .right:
                cell = CGRect(x: area.maxX - cellW, y: area.minY, width: cellW, height: area.height)
                other = CGRect(x: area.minX, y: area.minY, width: cellW, height: area.height)
                ha = .right
            }
            let inner = cell.insetBy(dx: CGFloat(b), dy: CGFloat(b))
            var w = Double(inner.width)
            var h = w / aspect
            if h > Double(inner.height) {
                h = Double(inner.height)
                w = h * aspect
            }
            rect = place(w, h, in: inner, hAlign: ha, vAlign: va)
        }

        return LayoutResult(canvasW: canvasW, canvasH: canvasH, pageW: pageW, pageH: pageH,
                            landscape: landscape, bleed: bleed, margin: sheet.margin,
                            rect: rect, trim: rect.insetBy(dx: CGFloat(-b), dy: CGFloat(-b)),
                            otherCell: other, cropMarks: marks)
    }

    /// Puts a w x h box inside avail using the alignment. If the box is bigger than the space, it is centered.
    private static func place(_ w: Double, _ h: Double, in avail: CGRect,
                              hAlign: HAlign, vAlign: VAlign) -> CGRect {
        let slackX = Double(avail.width) - w
        let slackY = Double(avail.height) - h
        let x = slackX >= 0 ? Double(avail.minX) + slackX * hAlign.factor : Double(avail.minX) + slackX / 2
        let y = slackY >= 0 ? Double(avail.minY) + slackY * vAlign.factor : Double(avail.minY) + slackY / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Papers

struct PaperPreset: Identifiable, Hashable {
    let id: String          // profile file name
    var name: String
    var url: URL
    var mediaCode: String
    var hidden: Bool
}

struct PaperOverride: Codable {
    var mediaCode: String?
    var hidden: Bool?
    var frontFeed: Bool?     // feed through the front "Thick" path instead of the top sheet feeder
    var overcoat: Bool?      // Black Enhance Overcoat
    var glossSmooth: Bool?   // Gloss Smoothing
    var bottomEdge: Bool?    // Bottom Edge Print Quality Priority
    var highSpeed: Bool?     // bidirectional printing (driver default in this app: on)
}

enum PaperCatalog {
    static func displayName(for file: String) -> String {
        let base = (file as NSString).deletingPathExtension
        let known: [String: String] = [
            "cifa_p900_baryta2_310_p_bk": "Canson Baryta II 310 (Cifa)",
            "cifa_p900_ragphot310_m_bk": "Canson Rag Photographique 310 (Cifa)",
            "Hannemuele_PhotoRag": "Hahnemühle Photo Rag",
        ]
        if let k = known[base] { return k }
        let epsonPrefix = "Epson_SC-P900_700_"
        if base.hasPrefix(epsonPrefix) {
            return "Epson " + splitCamel(String(base.dropFirst(epsonPrefix.count)))
        }
        if base.hasPrefix("RR ") {
            let rest = String(base.dropFirst(3)).replacingOccurrences(of: " EpP900", with: "")
            return "Red River " + rest
        }
        return base.replacingOccurrences(of: "_", with: " ")
    }

    static func splitCamel(_ s: String) -> String {
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0, ch.isUppercase, let last = out.last, last != " ", last != "-" {
                out.append(" ")
            }
            out.append(ch)
        }
        return out
    }

    /// First guess at the Epson media type for a profile. Editable in the app.
    static func guessMedia(for file: String) -> String {
        let n = file.lowercased()
        if n.contains("baryta") { return "157" }
        if n.contains("luster") || n.contains("lustre") { return "27" }
        if n.contains("canvassatin") { return "153" }
        if n.contains("canvasmatte") { return "155" }
        if n.contains("washi") { return "181" }
        if n.contains("watercolor") { return "17" }
        if n.contains("velvet") { return "53" }
        if n.contains("ultrasmooth") { return "88" }
        if n.contains("proofing") { return "106" }
        if n.contains("presentationpapermatte") { return "14" }
        if n.contains("premiumphotopapersemi") { return "15" }
        if n.contains("premiumphotopaperglossy") { return "13" }
        if n.contains("photopaperglossy") { return "145" }
        if n.contains("palo duro") || n.contains("aurora") { return "183" }
        if n.contains("satin") { return "15" }
        if n.contains("gloss") { return "13" }
        if n.contains("standard") { return "13" }
        return "183"
    }

    static func guessHidden(for file: String) -> Bool {
        let n = file.lowercased()
        return n.contains("canvas") || n.contains("washi") || n.contains("proofing") || n.contains("_standard")
    }

    static func build(overrides: [String: PaperOverride]) -> [PaperPreset] {
        var presets: [PaperPreset] = []
        for url in ProfileScanner.printerProfiles() {
            let file = url.lastPathComponent
            let o = overrides[file]
            presets.append(PaperPreset(
                id: file,
                name: displayName(for: file),
                url: url,
                mediaCode: o?.mediaCode ?? guessMedia(for: file),
                hidden: o?.hidden ?? guessHidden(for: file)
            ))
        }
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return presets
    }
}

// MARK: - ICC profile discovery

enum ProfileScanner {
    static var folders: [URL] {
        [
            URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles"),
            URL(fileURLWithPath: "/Library/Printers/EPSON/InkjetPrinter2/ICCProfiles/EP2010HK2.profiles/Contents/Resources"),
        ]
    }

    static func printerProfiles() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        let fm = FileManager.default
        for folder in folders {
            guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let url as URL in en {
                let ext = url.pathExtension.lowercased()
                guard ext == "icc" || ext == "icm" else { continue }
                let file = url.lastPathComponent
                if seen.contains(file) { continue }
                if isPrinterRGB(url) {
                    seen.insert(file)
                    result.append(url)
                }
            }
        }
        return result
    }

    /// True for output-class (printer) profiles with an RGB color space.
    static func isPrinterRGB(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 128), data.count == 128 else { return false }
        let cls = String(data: data.subdata(in: 12..<16), encoding: .ascii)
        let space = String(data: data.subdata(in: 16..<20), encoding: .ascii)
        return cls == "prtr" && space == "RGB "
    }
}
