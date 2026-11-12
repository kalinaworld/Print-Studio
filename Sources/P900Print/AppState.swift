import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AppTab: String { case print, printer, log }

/// Everything that makes up one print on the Print tab, so several can be open at once.
struct PrintSession: Identifiable {
    var id = UUID()
    var imageURL: URL?
    var preview: NSImage?
    var pixelSize: CGSize = .zero
    var sourceDPI: Double = 300
    var sourceProfileName = ""
    var dateTaken: Date?
    var mode: LayoutMode = .fit
    var orientation: PaperOrientation = .auto
    var border: Double = 0
    var customScale: Double = 1
    var copies = 1
    var paperID = ""
    var sheetID = "letter"
    var hAlign: HAlign = .center
    var vAlign: VAlign = .middle
    var halfPosition: HalfPosition = .top
    var cropMarks = false
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var logText = ""
    /// Settings to apply the next time this tab is shown (a reprint that finished opening while another tab was showing).
    var pendingApply: [String: String]?
}

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var tab: AppTab = .print
    @Published var themeChoice: ThemeChoice = .room {
        didSet { UserDefaults.standard.set(themeChoice.rawValue, forKey: "theme") }
    }
    /// Bumped by a timer so the Auto theme flips at dusk without a click.
    @Published var themeTick = 0

    var palette: Palette {
        switch themeChoice {
        case .room: return .room
        case .safelight: return .safelight
        case .auto:
            let h = Calendar.current.component(.hour, from: Date())
            return (h >= 18 || h < 6) ? .safelight : .room
        }
    }

    // Image
    @Published var imageURL: URL?
    @Published var preview: NSImage? = nil {
        didSet {
            // A different photo: drop anything computed from the old one so it never flashes on the new one.
            softProofImage = nil
            gamutMask = nil
            gamutOverlayFraction = nil
            fitNote = nil
            scheduleGamutRefresh()
        }
    }
    @Published var pixelSize: CGSize = .zero
    @Published var sourceDPI: Double = 300
    @Published var sourceProfileName: String = ""
    /// When the photo was taken, from the file's EXIF data. Nil if the file has none.
    @Published var dateTaken: Date? = nil

    // Papers
    @Published var papers: [PaperPreset] = []
    @Published var paperID: String = "" { didSet { save(); scheduleGamutRefresh() } }
    @Published var overrides: [String: PaperOverride] = [:] {
        didSet { saveOverrides(); rebuildPapers() }
    }

    // Layout
    @Published var sheetID: String = "letter" { didSet { save() } }
    @Published var orientation: PaperOrientation = .auto
    @Published var mode: LayoutMode = .fit { didSet { save() } }
    @Published var border: Double = 0 {
        didSet {
            let c = min(max(border, 0), LayoutEngine.maxBorderInches)
            if c != border { border = c }
            save()
        }
    }
    @Published var customScale: Double = 1
    /// Midtone brightness for this photo, -50...50. Starts at 0 for every new photo.
    @Published var brightness: Double = 0 { didSet { scheduleGamutRefresh() } }
    /// Contrast for this photo, -50...50. Positive adds an S-curve.
    @Published var contrast: Double = 0 { didSet { scheduleGamutRefresh() } }
    /// Color strength for this photo, -50...50. Positive makes colors stronger.
    @Published var saturation: Double = 0 { didSet { scheduleGamutRefresh() } }
    var tone: Tone { Tone(brightness: brightness, contrast: contrast, saturation: saturation) }
    private var previewCache: (id: ObjectIdentifier, v: Tone, img: NSImage)?
    /// The preview with the brightness applied, for the page preview only.
    var displayPreview: NSImage? {
        guard let p = preview else { return nil }
        let t = tone
        if t.isNeutral { return p }
        if let c = previewCache, c.id == ObjectIdentifier(p), c.v == t { return c.img }
        let out = Tone.adjusted(p, t)
        previewCache = (ObjectIdentifier(p), t, out)
        return out
    }
    @Published var hAlign: HAlign = .center { didSet { save() } }
    @Published var vAlign: VAlign = .middle { didSet { save() } }
    @Published var halfPosition: HalfPosition = .top { didSet { save() } }
    @Published var cropMarks: Bool = false { didSet { save() } }
    @Published var useCM: Bool = false { didSet { save() } }

    // Color
    @Published var intent: Intent = .relative { didSet { save(); scheduleGamutRefresh() } }
    @Published var blackPoint: Bool = true { didSet { save(); scheduleGamutRefresh() } }
    @Published var tagWithPaperProfile: Bool = false { didSet { save() } }

    // Gamut check
    /// Paints the colors the paper cannot print on the page preview.
    @Published var showGamut = false {
        didSet {
            if !showGamut { gamutMask = nil; gamutOverlayFraction = nil }
            scheduleGamutRefresh()
        }
    }
    @Published var gamutMask: NSImage? = nil
    /// Shows the photo as the chosen paper and intent will actually render it.
    @Published var softProof = false {
        didSet {
            if !softProof { softProofImage = nil }
            scheduleGamutRefresh()
        }
    }
    /// Also show the paper's own white and black, so the proof looks as flat and warm as the paper.
    @Published var simulatePaper = false { didSet { scheduleGamutRefresh() } }
    @Published var softProofImage: NSImage? = nil
    /// True while "Fit colors to paper" is searching.
    @Published var fitting = false
    /// What the last "Fit colors to paper" did, shown under the color controls.
    @Published var fitNote: String? = nil
    /// Share of the photo outside the paper's gamut for the chosen intent, while the overlay is on.
    @Published var gamutOverlayFraction: Double? = nil
    /// Measured with Relative Colorimetric, used for the intent suggestion.
    @Published var gamutReport: GamutReport? = nil
    private var gamutWork: DispatchWorkItem?
    private var gamutGen = 0

    // Job
    @Published var copies: Int = 1
    @Published var queue: String = P900.defaultQueue { didSet { save() } }
    @Published var isBusy = false
    /// What the Print button shows: normal, while the job is being prepared and sent, or briefly after it was sent.
    enum SendState { case idle, sending, sent }
    @Published var sendState: SendState = .idle
    @Published var logText = ""
    /// Every message from every print, with a time, for the Log tab. Survives New print and tab switching.
    @Published var activity: [String] = []

    // Open prints (tabs). The active one lives in the published properties above; the others are parked here.
    @Published var sessions: [PrintSession] = []
    @Published var activeID = UUID()

    private var allowQueueUntil = Date.distantPast
    private var allowCancelUntil = Date.distantPast

    private let inbox = InboxWatcher()
    private var pendingSettings: [String: String]?

    init() {
        let d = UserDefaults.standard
        if let v = d.string(forKey: "paperID") { paperID = v }
        // The sheet size always starts at 8.5 x 11, the most common one, instead of remembering the last used.
        if let v = d.string(forKey: "mode"), let m = LayoutMode(rawValue: v) { mode = m }
        if let v = d.string(forKey: "intent"), let i = Intent(rawValue: v) { intent = i }
        if let v = d.string(forKey: "hAlign"), let a = HAlign(rawValue: v) { hAlign = a }
        if let v = d.string(forKey: "vAlign"), let a = VAlign(rawValue: v) { vAlign = a }
        if let v = d.string(forKey: "half"), let a = HalfPosition(rawValue: v) { halfPosition = a }
        if d.object(forKey: "cropMarks") != nil { cropMarks = d.bool(forKey: "cropMarks") }
        if d.object(forKey: "border") != nil { border = d.double(forKey: "border") }
        if d.object(forKey: "useCM") != nil { useCM = d.bool(forKey: "useCM") }
        if let v = d.string(forKey: "theme"), let t = ThemeChoice(rawValue: v) { themeChoice = t }
        if d.object(forKey: "blackPoint") != nil { blackPoint = d.bool(forKey: "blackPoint") }
        if d.object(forKey: "tagV2") != nil { tagWithPaperProfile = d.bool(forKey: "tagV2") }
        if let v = d.string(forKey: "queue"), !v.isEmpty { queue = v }
        if let data = d.data(forKey: "overrides"),
           let o = try? JSONDecoder().decode([String: PaperOverride].self, from: data) {
            overrides = o
        }
        rebuildPapers()
        sessions = [PrintSession(id: activeID)]
    }

    // MARK: Gamut check

    /// Waits for the controls to settle, then re-checks the photo against the paper.
    func scheduleGamutRefresh() {
        gamutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runGamutRefresh() }
        gamutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func runGamutRefresh() {
        gamutGen += 1
        let gen = gamutGen
        guard let img = displayPreview, let paper = selectedPaper else {
            gamutReport = nil
            gamutMask = nil
            gamutOverlayFraction = nil
            softProofImage = nil
            return
        }
        let url = paper.url
        let name = paper.name
        let chosen = intent
        let bpc = blackPoint
        let wantMask = showGamut
        let wantProof = softProof
        let sim = simulatePaper
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var report: GamutReport?
            var mask: NSImage?
            var fraction: Double?
            var failure: String?
            var proof: NSImage?
            do {
                if wantProof {
                    proof = try SoftProof.render(image: img, paperURL: url, intent: chosen,
                                                 blackPoint: bpc, simulatePaper: sim, maxSide: 1600)
                }
                let r = try GamutCheck.scan(image: img, paperURL: url, intent: .relative,
                                            blackPoint: bpc, wantMask: false, maxSide: 900)
                report = GamutReport(paperName: name, stats: r.stats)
                if wantMask {
                    let m = try GamutCheck.scan(image: img, paperURL: url, intent: chosen,
                                                blackPoint: bpc, wantMask: true, maxSide: 1400)
                    mask = m.mask
                    fraction = Double(m.stats.outCount) / max(Double(m.stats.total), 1)
                }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self = self, gen == self.gamutGen else { return }
                self.gamutReport = report
                self.gamutMask = mask
                self.gamutOverlayFraction = fraction
                self.softProofImage = proof
                if let f = failure, wantMask || wantProof { self.logLine("Color preview: \(f)") }
            }
        }
    }

    /// Finds the gentlest Saturation setting that brings the photo (almost) inside what the paper can print,
    /// then sets the slider to it. Keeps your Brightness and Contrast as they are.
    func fitColorsToPaper() {
        guard let base = preview, let paper = selectedPaper, !fitting else { return }
        let url = paper.url
        let bpc = blackPoint
        let t0 = tone
        fitting = true
        fitNote = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func fraction(_ sat: Double) -> Double? {
                var t = t0
                t.saturation = sat
                let img = Tone.adjusted(base, t)
                guard let r = try? GamutCheck.scan(image: img, paperURL: url, intent: .relative,
                                                   blackPoint: bpc, wantMask: false, maxSide: 500) else { return nil }
                return Double(r.stats.outCount) / max(Double(r.stats.total), 1)
            }
            let target = 0.05          // fine with up to 5% still outside
            let floorSat = -35.0       // never desaturate more than this
            var note: String
            var result = t0.saturation
            if let start = fraction(t0.saturation) {
                func pct(_ f: Double) -> String { f < 0.1 ? String(format: "%.1f%%", f * 100) : String(format: "%.0f%%", f * 100) }
                if start <= target {
                    note = "Already fits: only \(pct(start)) is outside what this paper can print."
                } else if let atFloor = fraction(floorSat), atFloor > target {
                    result = floorSat
                    note = "Saturation \(Int(floorSat)) only gets this down from \(pct(start)) to \(pct(atFloor)), so I stopped there to keep the color alive. This photo is just more colorful than this paper. Easing the greens or yellows in Photoshop will do better than a global change."
                } else {
                    var lo = floorSat            // known to fit
                    var hi = t0.saturation       // known not to fit
                    for _ in 0..<6 {
                        let mid = (lo + hi) / 2
                        if let f = fraction(mid), f <= target { lo = mid } else { hi = mid }
                    }
                    result = lo.rounded(.down)
                    let after = fraction(result) ?? target
                    note = "Saturation set to \(Int(result)): outside the paper's range went from \(pct(start)) to \(pct(after)). Check the soft proof and add a little contrast if it feels flat."
                }
            } else {
                note = "Could not check this photo against the paper."
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fitting = false
                guard self.preview === base else { return }   // you moved on to another photo
                if result != self.saturation { self.saturation = result }
                self.fitNote = note
            }
        }
    }

    /// The suggestion shown under the intent picker, if the photo calls for one.
    var gamutTip: GamutAdvice.Tip? {
        guard let r = gamutReport else { return nil }
        return GamutAdvice.tip(report: r, current: intent)
    }

    /// The line under the page preview that says the picture is a soft proof.
    var proofLegend: String? {
        guard softProof, imageURL != nil else { return nil }
        guard softProofImage != nil else { return "Rendering soft proof…" }
        let paper = selectedPaper?.name ?? "this paper"
        var t = "Soft proof: \(paper), \(intent.label)"
        if blackPoint { t += ", black point compensation" }
        if simulatePaper { t += ", paper white and black simulated" }
        return t
    }

    /// The line under the page preview that explains the overlay colors.
    var gamutLegend: String? {
        guard showGamut, imageURL != nil else { return nil }
        let paper = selectedPaper?.name ?? "this paper"
        guard let f = gamutOverlayFraction, gamutMask != nil else { return "Checking gamut…" }
        if f <= 0 { return "Nothing in this photo falls outside what \(paper) can print (\(intent.label))." }
        let pct = f * 100
        let pctText = pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
        return "Magenta: outside what \(paper) can print with \(intent.label), \(pctText) of this photo."
    }

    // MARK: Persistence

    private func save() {
        let d = UserDefaults.standard
        d.set(paperID, forKey: "paperID")
        d.set(sheetID, forKey: "sheetID")
        d.set(mode.rawValue, forKey: "mode")
        d.set(intent.rawValue, forKey: "intent")
        d.set(blackPoint, forKey: "blackPoint")
        d.set(tagWithPaperProfile, forKey: "tagV2")
        d.set(queue, forKey: "queue")
        d.set(hAlign.rawValue, forKey: "hAlign")
        d.set(vAlign.rawValue, forKey: "vAlign")
        d.set(halfPosition.rawValue, forKey: "half")
        d.set(cropMarks, forKey: "cropMarks")
        d.set(border, forKey: "border")
        d.set(useCM, forKey: "useCM")
    }

    private func saveOverrides() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: "overrides")
        }
    }

    // MARK: Papers

    func rebuildPapers() {
        papers = PaperCatalog.build(overrides: overrides)
        let visible = papers.filter { !$0.hidden }
        if !visible.contains(where: { $0.id == paperID }) {
            let preferred = visible.first(where: { $0.id == "cifa_p900_ragphot310_m_bk.icc" })
            paperID = (preferred ?? visible.first)?.id ?? ""
        }
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        var o = overrides[id] ?? PaperOverride()
        o.hidden = hidden
        overrides[id] = o
    }

    func setMedia(_ id: String, _ code: String) {
        var o = overrides[id] ?? PaperOverride()
        o.mediaCode = code
        overrides[id] = o
    }

    /// Per-paper switches (front feed, overcoat, gloss smoothing, bottom edge), stored with the paper.
    func flag(_ key: KeyPath<PaperOverride, Bool?>, default d: Bool = false) -> Bool {
        overrides[paperID]?[keyPath: key] ?? d
    }

    func setFlag(_ key: WritableKeyPath<PaperOverride, Bool?>, _ value: Bool) {
        var o = overrides[paperID] ?? PaperOverride()
        o[keyPath: key] = value
        overrides[paperID] = o
    }

    var visiblePapers: [PaperPreset] { papers.filter { !$0.hidden } }
    var selectedPaper: PaperPreset? { papers.first(where: { $0.id == paperID }) }
    var selectedSheet: SheetSize { SheetSize.all.first(where: { $0.id == sheetID }) ?? SheetSize.all[0] }

    // MARK: Layout

    var layout: LayoutResult? {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return LayoutEngine.compute(sheet: selectedSheet, mode: mode, orientation: orientation,
                                    pixels: pixelSize, dpi: sourceDPI,
                                    borderInches: border, customScale: customScale,
                                    hAlign: hAlign, vAlign: vAlign, half: halfPosition,
                                    cropMarks: cropMarks)
    }

    /// Units for lengths shown in the controls. Everything is stored in inches.
    var unitName: String { useCM ? "cm" : "in" }
    var unitFactor: Double { useCM ? 2.54 : 1 }

    var canPrint: Bool { imageURL != nil && selectedPaper != nil && !isBusy }

    var summary: String {
        guard let l = layout else { return "Open or drop an image to begin." }
        let w = l.rect.width / 72
        let h = l.rect.height / 72
        let ppi = Double(pixelSize.width) / max(Double(w), 0.01)
        var s = String(format: "Prints %.1f × %.1f %@, %.0f ppi", Double(w) * unitFactor, Double(h) * unitFactor, unitName, ppi)
        if ppi < 180 { s += ", low resolution" }
        if l.bleed { s += ", edges trimmed to fill the sheet" }
        if mode == .half { s += ", other half left free" }
        if mode == .custom {
            let printableW = (l.pageW - 2 * l.margin) / 72
            let printableH = (l.pageH - 2 * l.margin) / 72
            if Double(w) > printableW + 0.01 || Double(h) > printableH + 0.01 {
                s += ", larger than the printable area"
            }
        }
        return s
    }

    // MARK: Loading images

    func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.tiff, .png, .jpeg]
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { load(url: u) }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
            if let url = url {
                DispatchQueue.main.async { self.load(url: url) }
            }
        }
        return true
    }

    // MARK: Open prints (tabs)

    var currentIsBlank: Bool { imageURL == nil && logText.isEmpty }

    /// Photos still being read from disk, per tab, so a second photo is never loaded on top of one that is still opening.
    private var loading: Set<UUID> = []
    private var loadSeq: [UUID: Int] = [:]

    /// True when this tab already holds a photo or is still opening one.
    var currentInUse: Bool { imageURL != nil || loading.contains(activeID) }

    func sessionTitle(_ x: PrintSession) -> String {
        let url = (x.id == activeID) ? imageURL : x.imageURL
        return url?.displayName ?? "New print"
    }

    func sessionThumb(_ x: PrintSession) -> NSImage? {
        (x.id == activeID) ? preview : x.preview
    }

    /// Copies the live state into the active session's slot.
    private func snapshotActive() {
        guard let i = sessions.firstIndex(where: { $0.id == activeID }) else { return }
        var x = sessions[i]
        x.imageURL = imageURL; x.preview = preview; x.pixelSize = pixelSize
        x.sourceDPI = sourceDPI; x.sourceProfileName = sourceProfileName; x.dateTaken = dateTaken
        x.mode = mode; x.orientation = orientation; x.border = border
        x.customScale = customScale; x.copies = copies
        x.paperID = paperID; x.sheetID = sheetID
        x.hAlign = hAlign; x.vAlign = vAlign; x.halfPosition = halfPosition
        x.cropMarks = cropMarks; x.brightness = brightness; x.contrast = contrast; x.saturation = saturation; x.logText = logText
        sessions[i] = x
    }

    private func restore(_ x: PrintSession) {
        imageURL = x.imageURL; preview = x.preview; pixelSize = x.pixelSize
        sourceDPI = x.sourceDPI; sourceProfileName = x.sourceProfileName; dateTaken = x.dateTaken
        mode = x.mode; orientation = x.orientation; border = x.border
        customScale = x.customScale; copies = x.copies
        if !x.paperID.isEmpty { paperID = x.paperID }
        sheetID = x.sheetID
        hAlign = x.hAlign; vAlign = x.vAlign; halfPosition = x.halfPosition
        cropMarks = x.cropMarks; brightness = x.brightness; contrast = x.contrast; saturation = x.saturation; logText = x.logText
        pendingSettings = nil
        if let p = x.pendingApply {
            apply(settings: p)
            if let i = sessions.firstIndex(where: { $0.id == x.id }) { sessions[i].pendingApply = nil }
        }
    }

    /// Blanks the live state. Paper, sheet size and color settings are kept, since those rarely
    /// change from one print to the next.
    private func clearLive() {
        imageURL = nil
        preview = nil
        pixelSize = .zero
        sourceDPI = 300
        sourceProfileName = ""
        dateTaken = nil
        pendingSettings = nil
        mode = .fit
        orientation = .auto
        customScale = 1
        brightness = 0
        contrast = 0
        saturation = 0
        copies = 1
        logText = ""
    }

    /// Parks the current print as a tab and starts a blank one.
    func newPrint() {
        guard !currentIsBlank else { return }
        snapshotActive()
        let fresh = PrintSession()
        sessions.append(fresh)
        activeID = fresh.id
        clearLive()
    }

    func switchTo(_ id: UUID) {
        guard id != activeID, let target = sessions.first(where: { $0.id == id }) else { return }
        snapshotActive()
        activeID = id
        restore(target)
    }

    func closeSession(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions.count == 1 {
            clearLive()
            return
        }
        if id == activeID {
            let next = sessions[i == 0 ? 1 : i - 1]
            sessions.remove(at: i)
            activeID = next.id
            restore(next)
        } else {
            sessions.remove(at: i)
        }
    }

    func load(url: URL) {
        // A load belongs to the tab that was showing when it started, even if you switch tabs before it finishes.
        let sid = activeID
        let seq = (loadSeq[sid] ?? 0) + 1
        loadSeq[sid] = seq
        loading.insert(sid)
        let settings = pendingSettings
        pendingSettings = nil
        logLine("Loading \(url.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                DispatchQueue.main.async {
                    guard let self = self, self.loadSeq[sid] == seq else { return }
                    self.loading.remove(sid)
                    self.logLine("Could not open \(url.lastPathComponent).")
                }
                return
            }
            let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
            func num(_ key: CFString) -> Double {
                (props[key as String] as? NSNumber)?.doubleValue ?? 0
            }
            let w = num(kCGImagePropertyPixelWidth)
            let h = num(kCGImagePropertyPixelHeight)
            var dpi = num(kCGImagePropertyDPIWidth)
            if dpi < 1 { dpi = 300 }
            let profile = (props[kCGImagePropertyProfileName as String] as? String) ?? "no profile"
            let orientation = Int(num(kCGImagePropertyOrientation))
            let exif = (props[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
            let rawDate = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
                ?? (exif[kCGImagePropertyExifDateTimeDigitized as String] as? String)
            let taken = rawDate.flatMap { AppState.exifDate($0) }

            let opts: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: 1800,
                kCGImageSourceShouldCacheImmediately as String: true,
            ]
            let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)

            DispatchQueue.main.async {
                guard let self = self, self.loadSeq[sid] == seq else { return }
                self.loading.remove(sid)
                guard w > 0, h > 0 else {
                    self.logLine("Could not read the size of \(url.lastPathComponent).")
                    return
                }
                let image: NSImage? = thumb.map { NSImage(cgImage: $0, size: .zero) }
                var msg = "Loaded \(url.lastPathComponent): \(Int(w)) × \(Int(h)) px, \(Int(dpi)) ppi, \(profile)."
                if orientation > 1 {
                    msg += "\nNote: the file has an EXIF rotation flag, which is not applied when printing."
                }
                if sid == self.activeID {
                    self.imageURL = url
                    self.pixelSize = CGSize(width: w, height: h)
                    self.sourceDPI = dpi
                    self.sourceProfileName = profile
                    self.dateTaken = taken
                    self.customScale = 1
                    self.brightness = 0
                    self.contrast = 0
                    self.saturation = 0
                    if let p = settings { self.apply(settings: p) }
                    if let img = image { self.preview = img }
                    self.logLine(msg)
                } else if let i = self.sessions.firstIndex(where: { $0.id == sid }) {
                    // You switched tabs while this was opening: fill in the tab it was meant for.
                    var x = self.sessions[i]
                    x.imageURL = url
                    x.pixelSize = CGSize(width: w, height: h)
                    x.sourceDPI = dpi
                    x.sourceProfileName = profile
                    x.dateTaken = taken
                    x.customScale = 1
                    x.brightness = 0
                    x.contrast = 0
                    x.saturation = 0
                    x.preview = image
                    x.pendingApply = settings
                    x.logText = x.logText.isEmpty ? msg : x.logText + "\n" + msg
                    self.sessions[i] = x
                }
            }
        }
    }

    /// EXIF dates look like "2021:10:12 16:32:05". They carry no time zone, so they are read as local time.
    static func exifDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for fmt in ["yyyy:MM:dd HH:mm:ss", "yyyy:MM:dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    func startInbox() {
        inbox.start { [weak self] url in
            guard let self = self else { return }
            // A photo sent from Photoshop gets its own tab if the current one is already in use,
            // so it never replaces a print you are setting up.
            self.tab = .print
            if self.currentInUse { self.newPrint() }
            self.load(url: url)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Settings snapshot and reprint

    func currentSettings() -> [String: String] {
        ["paperID": paperID, "sheetID": sheetID, "orientation": orientation.rawValue,
         "mode": mode.rawValue, "border": String(border), "customScale": String(customScale),
         "brightness": String(brightness), "contrast": String(contrast), "saturation": String(saturation),
         "hAlign": hAlign.rawValue, "vAlign": vAlign.rawValue, "half": halfPosition.rawValue,
         "cropMarks": cropMarks ? "1" : "0", "intent": intent.rawValue,
         "blackPoint": blackPoint ? "1" : "0", "copies": String(copies),
         "overcoat": flag(\.overcoat) ? "1" : "0",
         "glossSmooth": flag(\.glossSmooth) ? "1" : "0", "bottomEdge": flag(\.bottomEdge) ? "1" : "0",
         "highSpeed": flag(\.highSpeed, default: true) ? "1" : "0"]
    }

    func apply(settings d: [String: String]) {
        if let v = d["paperID"], papers.contains(where: { $0.id == v }) { paperID = v }
        if let v = d["sheetID"], SheetSize.all.contains(where: { $0.id == v }) { sheetID = v }
        if let v = d["orientation"], let o = PaperOrientation(rawValue: v) { orientation = o }
        if let v = d["mode"], let m = LayoutMode(rawValue: v) { mode = m }
        if let v = d["border"], let x = Double(v) { border = x }
        if let v = d["customScale"], let x = Double(v), x > 0 { customScale = x }
        if let v = d["brightness"], let x = Double(v) { brightness = min(max(x, Tone.range.lowerBound), Tone.range.upperBound) }
        if let v = d["contrast"], let x = Double(v) { contrast = min(max(x, Tone.range.lowerBound), Tone.range.upperBound) }
        if let v = d["saturation"], let x = Double(v) { saturation = min(max(x, Tone.range.lowerBound), Tone.range.upperBound) }
        if let v = d["hAlign"], let a = HAlign(rawValue: v) { hAlign = a }
        if let v = d["vAlign"], let a = VAlign(rawValue: v) { vAlign = a }
        if let v = d["half"], let a = HalfPosition(rawValue: v) { halfPosition = a }
        if let v = d["cropMarks"] { cropMarks = (v == "1") }
        if let v = d["intent"], let i = Intent(rawValue: v) { intent = i }
        if let v = d["blackPoint"] { blackPoint = (v == "1") }
        if let v = d["copies"], let c = Int(v), c > 0 { copies = c }
        if let v = d["overcoat"] { setFlag(\.overcoat, v == "1") }
        if let v = d["glossSmooth"] { setFlag(\.glossSmooth, v == "1") }
        if let v = d["bottomEdge"] { setFlag(\.bottomEdge, v == "1") }
        if let v = d["highSpeed"] { setFlag(\.highSpeed, v == "1") }
    }

    /// Loads a saved copy of a past print back in with the settings it was printed with.
    func reprint(_ r: PrintRecord) {
        guard let folder = r.folder, let name = r.sourceName else { return }
        tab = .print
        // Like a photo sent from Photoshop: if this print is already in use, park it as a tab first.
        if currentInUse { newPrint() }
        pendingSettings = r.settings
        load(url: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }

    /// Builds the printable test chart and loads it like any other image.
    func loadTestChart() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let u = try TestChart.make()
                DispatchQueue.main.async {
                    self?.tab = .print
                    self?.load(url: u)
                }
            } catch {
                DispatchQueue.main.async { self?.logLine("Error: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Printing

    func startPrint(dryRun: Bool) {
        guard !isBusy, let url = imageURL, let paper = selectedPaper, let lay = layout else { return }
        if !dryRun {
            guard let found = Spooler.resolveQueue(queue) else {
                logLine("No P900 print queue found. Add the printer in System Settings > Printers & Scanners using the Epson driver, then try again.")
                return
            }
            if found != queue {
                logLine("Print queue \"\(queue)\" was not found, using \"\(found)\" instead.")
                queue = found
            }
        }
        let job = PrintJob(imageURL: url, pixels: pixelSize, layout: lay, sheet: selectedSheet,
                           paper: paper, intent: intent, blackPoint: blackPoint,
                           tagWithPaperProfile: tagWithPaperProfile, queue: queue, copies: copies,
                           frontFeed: false, overcoat: flag(\.overcoat),
                           glossSmooth: flag(\.glossSmooth), bottomEdge: flag(\.bottomEdge),
                           highSpeed: flag(\.highSpeed, default: true),
                           tone: tone)
        let settingsSnapshot = currentSettings()
        let allowedUntil = allowQueueUntil
        let q = queue
        let previewSnapshot = preview
        let modeSnapshot = mode.rawValue
        isBusy = true
        if !dryRun { sendState = .sending }
        logLine(dryRun ? "Rendering PDF…" : "Preparing print…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if !dryRun {
                switch Spooler.preflight(queue: q) {
                case .ok:
                    break
                case .offline(let msg):
                    DispatchQueue.main.async { self?.isBusy = false; self?.sendState = .idle; self?.logLine(msg) }
                    return
                case .queued(let n):
                    if Date() >= allowedUntil {
                        DispatchQueue.main.async {
                            self?.isBusy = false
                            self?.sendState = .idle
                            self?.allowQueueUntil = Date().addingTimeInterval(20)
                            self?.logLine("\(n) job\(n == 1 ? " is" : "s are") already in the print queue, so nothing new was sent. Press Print again within 20 seconds to send this one anyway, or use Cancel all jobs.")
                        }
                        return
                    }
                }
            }
            do {
                let result = try job.run(dryRun: dryRun)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isBusy = false
                    self.logLine(result)
                    if !dryRun {
                        self.markSent()
                        PrintStats.shared.record(job: job, resultText: result,
                                                 coverage: Coverage.estimate(previewSnapshot),
                                                 mode: modeSnapshot,
                                                 thumbnail: previewSnapshot,
                                                 settings: settingsSnapshot)
                        PrintStats.shared.refreshAfterPrint(queue: self.queue)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.sendState = .idle
                    self?.logLine("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Shows "Sent to printer" on the Print button for a moment, then goes back to normal.
    private func markSent() {
        sendState = .sent
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.sendState == .sent { self?.sendState = .idle }
        }
    }

    /// Cancels every job waiting in or running through the printer's queue, and drops those jobs
    /// from the print history, since they never finished printing.
    /// Cancelling a job that is already being sent to the printer is the likeliest way to knock the
    /// P900 offline, so that case asks for a second press first.
    func cancelAllJobs() {
        let q = queue
        let allowedUntil = allowCancelUntil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = (InkReader.shell("/usr/bin/lpstat", ["-p", q]) ?? "").lowercased()
            if status.contains("now printing") && Date() >= allowedUntil {
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.allowCancelUntil = Date().addingTimeInterval(20)
                    self?.logLine("A job is being sent to the printer right now. Cancelling it from the Mac can knock the printer offline. It is safer to stop it with the printer's own cancel button. Press Cancel all jobs again within 20 seconds to cancel from the Mac anyway.")
                }
                return
            }
            // lpstat -o lines start with the job ID, e.g. "EPSON_SC_P900_Series-12 noah 123456 ..."
            let queued = (InkReader.shell("/usr/bin/lpstat", ["-o", q]) ?? "")
                .split(separator: "\n")
                .compactMap { $0.split(separator: " ").first.map(String.init) }
            _ = InkReader.shell("/usr/bin/cancel", ["-a", q])
            Thread.sleep(forTimeInterval: 4)
            let after = (InkReader.shell("/usr/bin/lpstat", ["-p", q]) ?? "").lowercased()
            let wentOffline = after.contains("offline") || after.contains("disabled") || after.contains("paused")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isBusy = false
                let stats = PrintStats.shared
                let doomed = stats.records.filter { !$0.jobID.isEmpty && queued.contains($0.jobID) }
                for r in doomed { stats.deleteRecord(r.id) }
                if queued.isEmpty {
                    self.logLine("Print queue was already empty.")
                } else {
                    let n = queued.count
                    self.logLine("Cancelled \(n) print job\(n == 1 ? "" : "s") and removed \(doomed.count) from history.")
                }
                if wentOffline {
                    self.logLine("The printer now shows as offline. Switch it off and on again, wait a minute, then print.")
                }
            }
        }
    }

    func logLine(_ s: String) {
        var lines = logText.isEmpty ? [] : logText.components(separatedBy: "\n")
        lines.append(contentsOf: s.components(separatedBy: "\n"))
        if lines.count > 40 { lines = Array(lines.suffix(40)) }
        logText = lines.joined(separator: "\n")

        let stamp = Self.logTimeFormat.string(from: Date())
        for part in s.components(separatedBy: "\n") where !part.isEmpty {
            activity.append("\(stamp)  \(part)")
        }
        if activity.count > 500 { activity = Array(activity.suffix(500)) }
    }

    private static let logTimeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
