import Foundation
import AppKit
import SwiftUI
import ImageIO

// MARK: - Ink constants

enum Ink {
    static let names = ["Matte Black", "Photo Black", "Gray", "Light Gray", "Cyan",
                        "Vivid Magenta", "Light Cyan", "Vivid Light Magenta", "Yellow", "Violet"]
    static let rgb: [(Double, Double, Double)] = [
        (0.20, 0.20, 0.20), (0.0, 0.0, 0.0), (0.60, 0.60, 0.60), (0.75, 0.75, 0.75),
        (0.0, 0.68, 0.94), (0.93, 0.0, 0.55), (0.56, 0.85, 0.97), (0.97, 0.68, 0.80),
        (1.0, 0.95, 0.0), (0.18, 0.19, 0.57),
    ]
    /// Brighter versions of the swatches for drawing on the dark UI (the two blacks and Violet vanish otherwise).
    static let display: [(Double, Double, Double)] = [
        (0.42, 0.44, 0.47), (0.13, 0.13, 0.14), (0.60, 0.60, 0.60), (0.78, 0.78, 0.78),
        (0.0, 0.68, 0.94), (0.93, 0.0, 0.55), (0.56, 0.85, 0.97), (0.97, 0.68, 0.80),
        (1.0, 0.95, 0.0), (0.32, 0.34, 0.85),
    ]
    /// The P900 prints with Matte Black on matte papers and Photo Black on glossy ones.
    static let matteCodes: Set<String> = ["183", "53", "88", "17", "181", "14", "2", "155"]
    static func blackInk(forMedia code: String) -> String {
        matteCodes.contains(code) ? "Matte Black" : "Photo Black"
    }
    static let sqInPer13x19: Double = 13 * 19
}

// MARK: - Stored data

struct PrintRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var paper: String
    var mediaCode: String
    var sheetID: String
    var mode: String
    var copies: Int
    var areaSqIn: Double      // per copy
    var coverage: Double      // rough 0...1 estimate of how dark the image is
    var jobID: String
    var blackInk: String
    var folder: String?       // history folder holding the file copy and thumbnail
    var sourceName: String?   // file name of the saved copy inside that folder
    var settings: [String: String]?
}

struct InkSnapshot: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var levels: [Int]         // one per cartridge, percent, -1 = unknown
    var source: String        // "cups" or "manual"
    var raw: String?          // printer status string at the time, kept so it can be decoded later
}

struct InkReading {
    var levels: [Int]
    var state: String
    var reasons: String
    var hasLevels: Bool { levels.contains(where: { $0 >= 0 }) }
}

struct ChannelStat: Identifiable {
    var id: Int
    var name: String
    var level: Int?
    var since: Date?
    var usedPoints: Double
    var prints: Int
    var sqIn: Double
    var sheetsLeft: Double?
}

// MARK: - Reading the printer

enum InkReader {
    static func shell(_ exe: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static var cachedURI: String?

    /// The printer's own IPP endpoint reports real ink levels, unlike the print queue.
    /// Prefers the address the CUPS queue already uses (works for ethernet queues set up with an
    /// ipp:// address), then falls back to finding the printer on the network with Bonjour.
    private static func discoverURI(queue: String) -> String? {
        if let v = shell("/usr/bin/lpstat", ["-v", queue]),
           let r = v.range(of: ": ") {
            let uri = v[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if uri.hasPrefix("ipp://") || uri.hasPrefix("ipps://") { return uri }
        }
        for pattern in ["EPSON*", "EPSON"] {
            guard let out = shell("/usr/bin/ippfind", ["-T", "4", "-n", pattern]) else { continue }
            let found = out.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("ipp") }
            if let f = found { return f }
        }
        return nil
    }

    private static func ask(_ uri: String) -> String? {
        shell("/usr/bin/ipptool", ["-tv", uri, "/usr/share/cups/ipptool/get-printer-attributes.test"])
    }

    private static func parse(_ out: String) -> InkReading? {
        var levels = [Int](repeating: -1, count: Ink.names.count)
        var state = "unknown"
        var reasons = ""
        for raw in out.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: " = ") else { continue }
            let value = String(line[r.upperBound...])
            if line.hasPrefix("marker-levels ") {
                let nums = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                for (i, n) in nums.enumerated() where i < levels.count { levels[i] = n }
            } else if line.hasPrefix("printer-state ") {
                state = value
            } else if line.hasPrefix("printer-state-reasons ") {
                reasons = value
            }
        }
        if state == "unknown" && reasons.isEmpty { return nil }
        return InkReading(levels: levels, state: state, reasons: reasons)
    }

    /// Reads supply levels straight from the printer, falling back to the CUPS queue.
    static func read(queue: String) -> InkReading? {
        // 1. The printer's own IPP endpoint (real levels)
        var uri = cachedURI
        var out: String? = uri.flatMap { ask($0) }
        if out == nil || parse(out!) == nil {
            uri = discoverURI(queue: queue)
            cachedURI = uri
            out = uri.flatMap { ask($0) }
        }
        if let o = out, let r = parse(o), r.hasLevels { return r }

        // 2. The print queue (usually reports -1 for every cartridge)
        if let o = shell("/usr/bin/ipptool",
                         ["-tv", "ipp://localhost/printers/\(queue)",
                          "/usr/share/cups/ipptool/get-printer-attributes.test"]) {
            return parse(o)
        }
        return nil
    }
}

// MARK: - Image darkness estimate

enum Coverage {
    /// 0 = blank white, 1 = solid black. Rough proxy for how much ink a picture wants.
    static func estimate(_ image: NSImage?) -> Double {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0.3 }
        let w = 64, h = 64
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return 0.3 }
        let sum = buf.reduce(0) { $0 + Int($1) }
        return 1 - Double(sum) / Double(w * h * 255)
    }
}

// MARK: - Store and analytics

final class PrintStats: ObservableObject {
    static let shared = PrintStats()

    @Published var records: [PrintRecord] = []
    @Published var snapshots: [InkSnapshot] = []
    @Published var reading: InkReading?
    @Published var readNote = ""

    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("P900Print", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        records = load("prints.json")
        snapshots = load("ink.json")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.compactHistory() }
    }

    // MARK: Keeping history small

    /// How many of the newest prints keep their full-size file copy.
    static let keepFullCopies = 20
    private var compacting = false

    /// Older prints keep everything (thumbnail, settings, a reprintable copy), but the big TIFF is
    /// swapped for a high quality JPEG, which is roughly a tenth of the size. Nothing is removed from history.
    func compactHistory() {
        guard !compacting else { return }
        let newestFirst = records.sorted { $0.date > $1.date }
        let old = newestFirst.dropFirst(Self.keepFullCopies)
        let todo: [(UUID, String, String)] = old.compactMap { r in
            guard let folder = r.folder, let name = r.sourceName else { return nil }
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["tif", "tiff", "png"].contains(ext) else { return nil }
            return (r.id, folder, name)
        }
        guard !todo.isEmpty else { return }
        compacting = true
        let root = Self.historyRoot.standardizedFileURL.path + "/"

        DispatchQueue.global(qos: .background).async { [weak self] in
            var changed: [UUID: String] = [:]
            let fm = FileManager.default
            for (id, folder, name) in todo {
                let dir = URL(fileURLWithPath: folder)
                let src = dir.appendingPathComponent(name)
                // Only ever touch files inside the app's own history folder.
                guard src.standardizedFileURL.path.hasPrefix(root), fm.fileExists(atPath: src.path) else { continue }
                let newName = (name as NSString).deletingPathExtension + ".jpg"
                let dst = dir.appendingPathComponent(newName)
                guard let imgSrc = CGImageSourceCreateWithURL(src as CFURL, nil),
                      let dest = CGImageDestinationCreateWithURL(dst as CFURL, "public.jpeg" as CFString, 1, nil) else { continue }
                let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
                CGImageDestinationAddImageFromSource(dest, imgSrc, 0, opts as CFDictionary)
                guard CGImageDestinationFinalize(dest),
                      let size = (try? fm.attributesOfItem(atPath: dst.path))?[.size] as? Int, size > 10_000 else {
                    try? fm.removeItem(at: dst)
                    continue
                }
                try? fm.removeItem(at: src)    // the JPEG exists and is non-empty, so the big copy can go
                changed[id] = newName
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.compacting = false
                guard !changed.isEmpty else { return }
                for i in self.records.indices {
                    if let n = changed[self.records[i].id] { self.records[i].sourceName = n }
                }
                self.store(self.records, "prints.json")
            }
        }
    }

    private func load<T: Decodable>(_ name: String) -> [T] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let v = try? dec.decode([T].self, from: data) else { return [] }
        return v
    }

    private func store<T: Encodable>(_ v: [T], _ name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(v) {
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
    }

    // MARK: Recording

    static let historyRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/P900 Print History", isDirectory: true)

    func openHistoryFolder() {
        try? FileManager.default.createDirectory(at: Self.historyRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.historyRoot)
    }

    static func jpeg(_ img: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let k = min(1, maxSide / max(w, h, 1))
        let tw = max(1, Int(w * k)), th = max(1, Int(h * k))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg,
                                                             properties: [.compressionFactor: 0.85])
    }

    /// Logs a print and saves a copy of the file, a thumbnail and the settings in ~/Pictures/P900 Print History.
    func record(job: PrintJob, resultText: String, coverage: Double, mode: String,
                thumbnail: NSImage?, settings: [String: String]) {
        var jobID = ""
        if let r = resultText.range(of: "request id is ") {
            jobID = String(resultText[r.upperBound...].prefix { !$0.isWhitespace })
        }
        let area = Double(job.layout.rect.width * job.layout.rect.height) / 5184.0
        var rec = PrintRecord(date: Date(),
                              title: job.imageURL.displayName,
                              paper: job.paper.name, mediaCode: job.paper.mediaCode,
                              sheetID: job.sheet.id, mode: mode, copies: max(1, job.copies),
                              areaSqIn: area, coverage: coverage, jobID: jobID,
                              blackInk: Ink.blackInk(forMedia: job.paper.mediaCode))
        rec.settings = settings
        let source = job.imageURL
        let base = rec

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var finished = base
            let fm = FileManager.default
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HHmmss"
            let safe = base.title.replacingOccurrences(of: "/", with: "-")
            let folder = Self.historyRoot.appendingPathComponent("\(f.string(from: base.date)) \(safe)",
                                                                 isDirectory: true)
            if (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil {
                finished.folder = folder.path
                let dest = folder.appendingPathComponent(source.lastPathComponent)
                if (try? fm.copyItem(at: source, to: dest)) != nil {
                    finished.sourceName = dest.lastPathComponent
                }
                if let t = thumbnail, let data = Self.jpeg(t, maxSide: 600) {
                    try? data.write(to: folder.appendingPathComponent("thumb.jpg"))
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.records.append(finished)
                self.store(self.records, "prints.json")
                self.compactHistory()
            }
        }
    }

    /// Removes a history entry (for a job that never printed) and moves its saved copy to the Trash.
    func deleteRecord(_ id: UUID) {
        if let f = records.first(where: { $0.id == id })?.folder {
            let u = URL(fileURLWithPath: f)
            // Only ever touch folders inside the app's own history folder.
            if u.standardizedFileURL.path.hasPrefix(Self.historyRoot.standardizedFileURL.path + "/") {
                try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
            }
        }
        records.removeAll { $0.id == id }
        store(records, "prints.json")
    }

    // MARK: Ink levels

    /// Never talk to the printer directly while a job is queued or printing: a second conversation
    /// with the printer at that moment is a suspect for it dropping offline.
    private static func queueIsBusy(_ queue: String) -> Bool {
        !(InkReader.shell("/usr/bin/lpstat", ["-o", queue]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshInk(queue: String, retryWhenBusy: Bool = false) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if Self.queueIsBusy(queue) {
                DispatchQueue.main.async {
                    self?.readNote = "Ink check paused while a job is printing."
                    if retryWhenBusy {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                            self?.refreshInk(queue: queue, retryWhenBusy: true)
                        }
                    }
                }
                return
            }
            let r = InkReader.read(queue: queue)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reading = r
                guard let r = r else {
                    self.readNote = "Could not talk to the print queue \(queue)."
                    return
                }
                if r.hasLevels {
                    self.readNote = "Levels read from the printer."
                    let last = self.snapshots.last
                    if last == nil || last!.levels != r.levels {
                        self.snapshots.append(InkSnapshot(date: Date(), levels: r.levels,
                                                          source: "cups", raw: r.reasons))
                        self.store(self.snapshots, "ink.json")
                    }
                } else {
                    self.readNote = "The printer is not reporting levels right now."
                }
            }
        }
    }

    /// Check again shortly after a print, in case the printer reports levels.
    func refreshAfterPrint(queue: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.refreshInk(queue: queue, retryWhenBusy: true)
        }
    }

    /// Levels typed in from System Settings > Printers > Supply Levels.
    func addManual(levels: [Int], queue: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let raw = InkReader.read(queue: queue)?.reasons
            DispatchQueue.main.async {
                guard let self = self else { return }
                let clean = levels.map { max(-1, min(100, $0)) }
                self.snapshots.append(InkSnapshot(date: Date(), levels: clean, source: "manual", raw: raw))
                self.store(self.snapshots, "ink.json")
            }
        }
    }

    var latestLevels: [Int] {
        snapshots.last?.levels ?? [Int](repeating: -1, count: Ink.names.count)
    }

    var hasAutoLevels: Bool { reading?.hasLevels ?? false }

    // MARK: Analytics

    private func uses(_ channel: Int, _ r: PrintRecord) -> Bool {
        if channel == 0 { return r.blackInk == "Matte Black" }
        if channel == 1 { return r.blackInk == "Photo Black" }
        return true
    }

    func channelStats() -> [ChannelStat] {
        (0..<Ink.names.count).map { i in
            let snaps = snapshots
                .filter { $0.levels.count > i && $0.levels[i] >= 0 }
                .sorted { $0.date < $1.date }
            guard let last = snaps.last else {
                return ChannelStat(id: i, name: Ink.names[i], level: nil, since: nil,
                                   usedPoints: 0, prints: 0, sqIn: 0, sheetsLeft: nil)
            }
            // A jump up of more than 10 points means a fresh cartridge went in.
            var startIdx = 0
            if snaps.count > 1 {
                for k in 1..<snaps.count where snaps[k].levels[i] > snaps[k - 1].levels[i] + 10 {
                    startIdx = k
                }
            }
            let start = snaps[startIdx]
            let used = Double(start.levels[i] - last.levels[i])
            let recs = records.filter { $0.date > start.date && $0.date <= last.date && uses(i, $0) }
            let prints = recs.reduce(0) { $0 + $1.copies }
            let sq = recs.reduce(0.0) { $0 + $1.areaSqIn * Double($1.copies) }
            var left: Double? = nil
            if used >= 2, sq > 0 {
                left = Double(last.levels[i]) / (used / sq) / Ink.sqInPer13x19
            }
            return ChannelStat(id: i, name: Ink.names[i], level: last.levels[i], since: start.date,
                               usedPoints: used, prints: prints, sqIn: sq, sheetsLeft: left)
        }
    }

    var totalPrints: Int { records.reduce(0) { $0 + $1.copies } }
    var totalSqFt: Double { records.reduce(0.0) { $0 + $1.areaSqIn * Double($1.copies) } / 144 }

    var printsLast30Days: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        return records.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.copies }
    }

    func counts(by key: (PrintRecord) -> String) -> [(String, Int)] {
        var d: [String: Int] = [:]
        for r in records { d[key(r), default: 0] += r.copies }
        return d.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// Times the printer had to change between Matte Black and Photo Black, which costs ink.
    var blackSwitches: Int {
        var n = 0
        let sorted = records.sorted { $0.date < $1.date }
        for k in 1..<max(sorted.count, 1) where sorted[k].blackInk != sorted[k - 1].blackInk { n += 1 }
        return n
    }
}
