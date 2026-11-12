import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var s: AppState
    @ObservedObject private var mon = PrinterMonitor.shared

    /// The status pill only appears when there is something to report.
    private var showStatus: Bool {
        switch mon.phase {
        case .printing, .waiting, .offline: return true
        case .idle, .unknown: return false
        }
    }

    var body: some View {
        Group {
            if s.tab == .log {
                LogView()
            } else if s.tab == .print {
                VStack(spacing: 0) {
                    if s.sessions.count > 1 { SessionStrip() }
                    HStack(spacing: 0) {
                    PreviewPane()
                        .frame(minWidth: 440)
                    Divider()
                    ControlsPane()
                        .frame(width: 380)
                    }
                }
            } else {
                StatsView()
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(s.palette.bg)
        .fontDesign(.monospaced)
        .tint(s.palette.accent)
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
            s.themeTick += 1
        }
        .onAppear { mon.refresh(queue: s.queue) }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            mon.refresh(queue: s.queue)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { s.newPrint() } label: {
                    Label("New print", systemImage: "square.and.pencil")
                }
                .help("New print: park this one as a tab and start fresh (Cmd-N)")
                .disabled(s.currentIsBlank || s.tab != .print)
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Theme", selection: $s.themeChoice) {
                        ForEach(ThemeChoice.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Show Log") { s.tab = .log }
                        .keyboardShortcut("l", modifiers: .command)
                } label: {
                    Image(systemName: s.palette.safelight ? "moon.fill" : "sun.max")
                }
                .help("Theme and log")
            }
            ToolbarItem(placement: .primaryAction) {
                if showStatus { StatusPill() }
            }
            ToolbarItem(placement: .principal) {
                Picker("", selection: $s.tab) {
                    Text("Print").tag(AppTab.print)
                    Text("Printer").tag(AppTab.printer)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            s.handleDrop(providers)
        }
    }
}

// MARK: - Open prints

struct SessionStrip: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(s.sessions) { x in
                    let active = x.id == s.activeID
                    HStack(spacing: 0) {
                        Button { s.switchTo(x.id) } label: {
                            HStack(spacing: 6) {
                                if let t = s.sessionThumb(x) {
                                    Image(nsImage: t).resizable().scaledToFill()
                                        .frame(width: 22, height: 22)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                                Text(s.sessionTitle(x)).lineLimit(1).font(.callout)
                            }
                            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Switch to this print")
                        Button { s.closeSession(x.id) } label: {
                            Image(systemName: "xmark").font(.caption2)
                                .padding(.leading, 2).padding(.trailing, 10).padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Close this print")
                    }
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(active ? s.palette.tile : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(active ? s.palette.accent : s.palette.line, lineWidth: 1))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(s.palette.panel)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Preview

struct PreviewPane: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    if let l = s.layout, let img = s.displayPreview {
                        PagePreview(layout: l, image: (s.softProof ? s.softProofImage : nil) ?? img,
                                    mask: s.showGamut ? s.gamutMask : nil,
                                    size: geo.size)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("Drop an image here, or press ⌘O")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            Text(s.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, (s.gamutLegend == nil && s.proofLegend == nil) ? 10 : 0)
            if let proofLegend = s.proofLegend {
                Text(proofLegend)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, s.gamutLegend == nil ? 10 : 0)
            }
            if let legend = s.gamutLegend {
                Text(legend)
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0xFF4DFF))
                    .padding(.bottom, 10)
            }
        }
        .background(s.palette.pane)
    }
}

struct PagePreview: View {
    let layout: LayoutResult
    let image: NSImage
    var mask: NSImage? = nil
    let size: CGSize

    var body: some View {
        let pad: CGFloat = 28
        let scale = min((size.width - pad * 2) / CGFloat(layout.pageW),
                        (size.height - pad * 2) / CGFloat(layout.pageH))
        let pw = CGFloat(layout.pageW) * scale
        let ph = CGFloat(layout.pageH) * scale
        let r = layout.rect
        let m = CGFloat(layout.margin) * scale

        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white)
            Image(nsImage: image)
                .resizable()
                .frame(width: r.width * scale, height: r.height * scale)
                .offset(x: r.minX * scale, y: (CGFloat(layout.pageH) - r.maxY) * scale)
            if let m = mask {
                Image(nsImage: m)
                    .resizable()
                    .frame(width: r.width * scale, height: r.height * scale)
                    .offset(x: r.minX * scale, y: (CGFloat(layout.pageH) - r.maxY) * scale)
                    .allowsHitTesting(false)
            }
            if !layout.bleed {
                Rectangle()
                    .strokeBorder(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(m)
            }
            if let oc = layout.otherCell {
                Rectangle()
                    .strokeBorder(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .frame(width: oc.width * scale, height: oc.height * scale)
                    .offset(x: oc.minX * scale, y: (CGFloat(layout.pageH) - oc.maxY) * scale)
            }
            if layout.cropMarks {
                MarksShape(rect: layout.trim, pageH: CGFloat(layout.pageH), scale: scale)
                    .stroke(Color.black, lineWidth: 0.8)
            }
        }
        .frame(width: pw, height: ph, alignment: .topLeading)
        .clipped()
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

// MARK: - Controls

struct ControlsPane: View {
    @EnvironmentObject var s: AppState
    @State private var showPapers = false

    private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                imageInfo

                section("Paper") {
                    HStack {
                        Picker("", selection: $s.paperID) {
                            ForEach(s.visiblePapers) { p in
                                Text(p.name).tag(p.id)
                            }
                        }
                        .labelsHidden()
                        Button("Edit…") { showPapers = true }
                    }
                    if let p = s.selectedPaper {
                        Text("Printer media: \(P900.mediaName(p.mediaCode))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                section("Sheet") {
                    Picker("", selection: $s.sheetID) {
                        ForEach(SheetSize.all) { sh in
                            Text(sh.label).tag(sh.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Picker("", selection: $s.orientation) {
                        ForEach(PaperOrientation.allCases) { o in
                            Text(o.label).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Divider().opacity(0.6)
                section("Layout") {
                    Picker("", selection: $s.mode) {
                        ForEach(LayoutMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack {
                        Text("Units")
                        Picker("", selection: $s.useCM) {
                            Text("in").tag(false)
                            Text("cm").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 90)
                    }

                    if s.mode != .bleed {
                        HStack {
                            Text("Border")
                            Slider(value: borderBinding, in: 0...(LayoutEngine.maxBorderInches * s.unitFactor))
                            TextField("0", value: borderBinding, format: numberFormat)
                                .frame(width: 50)
                            Text(s.unitName)
                        }
                    }
                    if s.mode == .custom {
                        HStack {
                            Text("Scale")
                            TextField("100", value: scaleBinding, format: numberFormat)
                                .frame(width: 70)
                            Text("%")
                        }
                        HStack {
                            Text("W")
                            TextField("", value: widthBinding, format: numberFormat)
                                .frame(width: 60)
                            Text("H")
                            TextField("", value: heightBinding, format: numberFormat)
                                .frame(width: 60)
                            Text(s.unitName)
                        }
                    }
                    if s.mode == .half {
                        Picker("", selection: $s.halfPosition) {
                            ForEach(HalfPosition.allCases) { h in
                                Text(h.label).tag(h)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Leaves the other half free for a second print of the same size, at least \(halfGapText) away.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if s.mode == .fit || s.mode == .custom {
                        Picker("", selection: $s.vAlign) {
                            ForEach(VAlign.allCases) { v in
                                Text(v.label).tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Picker("", selection: $s.hAlign) {
                            ForEach(HAlign.allCases) { h in
                                Text(h.label).tag(h)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Toggle("Crop marks", isOn: $s.cropMarks)
                        .disabled(s.mode == .bleed)
                    if s.cropMarks && s.mode != .bleed {
                        Text(s.border > 0 ? "Marks sit at the outer edge of the border, so you trim there."
                                          : "Add a border above and the marks will sit at its outer edge.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.6)
                section("Color") {
                    Picker("", selection: $s.intent) {
                        ForEach(Intent.allCases) { i in
                            Text(i.label).tag(i)
                        }
                    }
                    .labelsHidden()
                    GamutAdviceView()
                    if let note = s.fitNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    switchRow("Black point compensation", $s.blackPoint,
                              help: "Maps the photo's darkest black to the paper's darkest black so shadows keep their detail")

                    subhead("Preview")
                    switchRow("Soft proof", $s.softProof,
                              help: "Shows the photo on screen as the chosen paper and intent will render it, using the same conversion as the print")
                    if s.softProof {
                        switchRow("Simulate paper white and black", $s.simulatePaper,
                                  help: "Keeps the paper's own white and black instead of mapping them to screen white and black. Matte papers look flatter and a little warmer, like the real print.",
                                  indent: true)
                    }
                    switchRow("Highlight colors it can't print", $s.showGamut,
                              help: "Paints the out-of-gamut colors magenta on the page preview, using the paper and intent chosen here")

                    HStack {
                        subhead("Adjust")
                        Spacer()
                        Button("Reset all") { s.brightness = 0; s.contrast = 0; s.saturation = 0 }
                            .controlSize(.small)
                            .disabled(s.tone.isNeutral)
                    }
                    ToneSlider(title: "Brightness", value: $s.brightness)
                    ToneSlider(title: "Contrast", value: $s.contrast)
                    ToneSlider(title: "Saturation", value: $s.saturation)
                    Text("Brightness and contrast keep pure black and white put. Everything here applies to the print, the preview and the soft proof.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.6)
                section("Print") {
                    Stepper("Copies: \(s.copies)", value: $s.copies, in: 1...20)
                        .padding(.bottom, 4)
                    Button { s.startPrint(dryRun: false) } label: {
                        HStack(spacing: 8) {
                            if s.sendState == .sending {
                                ProgressView().controlSize(.small)
                            } else if s.sendState == .sent {
                                Image(systemName: "checkmark")
                            }
                            Text(printButtonTitle)
                        }
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!s.canPrint)
                    HStack(spacing: 10) {
                        Button { s.startPrint(dryRun: true) } label: {
                            Text("Preview PDF").frame(maxWidth: .infinity)
                        }
                        .disabled(!s.canPrint)
                        Button(role: .destructive) { s.cancelAllJobs() } label: {
                            Text("Cancel all jobs").frame(maxWidth: .infinity)
                        }
                        .help("Clears every job from the P900 print queue")
                    }
                    .controlSize(.large)
                    Text("Fixed: Max Quality, 5760 dpi, driver color management off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Extras (this paper)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Black Enhance Overcoat", isOn: Binding(get: { s.flag(\.overcoat) },
                                                                      set: { s.setFlag(\.overcoat, $0) }))
                        Toggle("Gloss Smoothing", isOn: Binding(get: { s.flag(\.glossSmooth) },
                                                               set: { s.setFlag(\.glossSmooth, $0) }))
                        Toggle("Bottom edge quality priority", isOn: Binding(get: { s.flag(\.bottomEdge) },
                                                                            set: { s.setFlag(\.bottomEdge, $0) }))
                        Toggle("High speed (prints both directions)", isOn: Binding(get: { s.flag(\.highSpeed, default: true) },
                                                                                   set: { s.setFlag(\.highSpeed, $0) }))
                        Text("These change how much ink goes down, so a custom profile may match a little less closely. Off by default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Print queue")
                            TextField("", text: $s.queue)
                        }
                        Toggle("Tag PDF with paper profile (tested: leave off)", isOn: $s.tagWithPaperProfile)
                        Button("Load test chart") { s.loadTestChart() }
                        Text("An 8.5 x 11 chart with color patches, gray steps, gradients and fine lines, for comparing settings on paper.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }

                if let last = s.logText.components(separatedBy: "\n")
                    .last(where: { !$0.isEmpty && !$0.hasPrefix("lp ") }) {
                    // Just the latest plain-language message; the full detail lives on the Log tab.
                    Button { s.tab = .log } label: {
                        Text(last)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Open the Log tab for the full details")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .background(s.palette.panel)
        .sheet(isPresented: $showPapers) {
            PapersSheet().environmentObject(s)
        }
    }

    // MARK: pieces

    private var imageInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(s.imageURL.map { $0.displayName + "." + $0.pathExtension } ?? "No image")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if s.imageURL != nil {
                    dateTakenBadge
                }
            }
            if s.imageURL != nil {
                Text("\(Int(s.pixelSize.width)) × \(Int(s.pixelSize.height)) px · \(Int(s.sourceDPI)) ppi · \(s.sourceProfileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var printButtonTitle: String {
        switch s.sendState {
        case .sending: return "Sending…"
        case .sent: return "Sent to printer"
        case .idle: return s.copies > 1 ? "Print \(s.copies) copies" : "Print"
        }
    }

    /// The date the photo was taken, to write on the back of the print.
    private var dateTakenBadge: some View {
        Group {
            if let d = s.dateTaken {
                Text(d.formatted(date: .abbreviated, time: .omitted))
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(s.palette.tile))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(s.palette.line, lineWidth: 1))
                    .textSelection(.enabled)
                    .help("Photo taken \(d.formatted(date: .long, time: .shortened))")
            } else {
                Text("No date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This file has no capture date in its metadata")
            }
        }
        .fixedSize()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    /// A label on the left and a small switch on the right.
    private func switchRow(_ title: String, _ isOn: Binding<Bool>, help: String = "", indent: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.leading, indent ? 16 : 0)
        .help(help)
    }

    private func subhead(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private var scaleBinding: Binding<Double> {
        Binding(get: { s.customScale * 100 },
                set: { v in if v > 0 { s.customScale = v / 100 } })
    }

    private var borderBinding: Binding<Double> {
        Binding(get: { s.border * s.unitFactor },
                set: { v in s.border = max(0, v) / s.unitFactor })
    }

    private var halfGapText: String {
        let inches = s.cropMarks ? 0.75 : 0.5
        return s.useCM ? String(format: "%.1f cm", inches * 2.54) : String(format: "%.2g in", inches)
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { Double(s.pixelSize.width) / max(s.sourceDPI, 1) * s.customScale * s.unitFactor },
                set: { v in
                    if v > 0, s.pixelSize.width > 0 {
                        s.customScale = (v / s.unitFactor) * s.sourceDPI / Double(s.pixelSize.width)
                    }
                })
    }

    private var heightBinding: Binding<Double> {
        Binding(get: { Double(s.pixelSize.height) / max(s.sourceDPI, 1) * s.customScale * s.unitFactor },
                set: { v in
                    if v > 0, s.pixelSize.height > 0 {
                        s.customScale = (v / s.unitFactor) * s.sourceDPI / Double(s.pixelSize.height)
                    }
                })
    }
}

// MARK: - Gamut suggestion

struct GamutAdviceView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        if let tip = s.gamutTip {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(s.palette.accent)
                    Text(tip.text)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if let target = tip.suggest {
                        Button("Use \(target.label)") { s.intent = target }
                    }
                    if !s.showGamut {
                        Button("Show where") { s.showGamut = true }
                    }
                    if let r = s.gamutReport, r.outFraction >= 0.02 {
                        Button(s.fitting ? "Fitting…" : "Auto-fit") { s.fitColorsToPaper() }
                            .disabled(s.fitting)
                            .help("Lowers Saturation just enough to bring the photo (nearly) inside what this paper can print")
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(s.palette.tile))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(s.palette.accent.opacity(0.6), lineWidth: 1))
        }
    }
}

// MARK: - Paper list editor

struct PapersSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Papers").font(.headline)
            Text("Printer profiles found in your ColorSync folders. Untick the ones you never use, and check that each one is paired with the right printer media type.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(s.papers) { p in
                HStack {
                    Toggle("", isOn: Binding(get: { !p.hidden }, set: { s.setHidden(p.id, !$0) }))
                        .labelsHidden()
                    Text(p.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("", selection: Binding(get: { p.mediaCode }, set: { s.setMedia(p.id, $0) })) {
                        ForEach(P900.mediaTypes) { m in
                            Text(m.name).tag(m.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 660, height: 540)
    }
}

struct MarksShape: Shape {
    let rect: CGRect
    let pageH: CGFloat
    let scale: CGFloat

    func path(in _: CGRect) -> Path {
        var p = Path()
        for (a, b) in CropMarks.segments(for: rect) {
            p.move(to: CGPoint(x: a.x * scale, y: (pageH - a.y) * scale))
            p.addLine(to: CGPoint(x: b.x * scale, y: (pageH - b.y) * scale))
        }
        return p
    }
}


/// One -50...50 tone slider: name and value on top, the slider full width below.
struct ToneSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                Text(String(format: "%+d", Int(value.rounded())))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? .secondary : .primary)
                Button { value = 0 } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(value == 0)
                .help("Reset \(title.lowercased())")
            }
            Slider(value: $value, in: Tone.range, step: 1)
                .controlSize(.small)
        }
    }
}
