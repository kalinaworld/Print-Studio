import SwiftUI
import AppKit

struct StatsView: View {
    @EnvironmentObject var s: AppState
    @ObservedObject var stats = PrintStats.shared
    @State private var showLevels = false
    @Environment(\.openWindow) private var openWindow
    /// How many prints the Printer tab shows. The rest are in the All Prints window.
    private let recentCount = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                inkSection
                summarySection
                breakdownSection
                historySection
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(s.palette.pane)
        .onAppear { stats.refreshInk(queue: s.queue) }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            stats.refreshInk(queue: s.queue)
        }
        .sheet(isPresented: $showLevels) {
            LevelsSheet(stats: stats, queue: s.queue)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EPSON SC-P900").font(.title2.weight(.semibold))
                Text("Printer is \(stats.reading?.state ?? "unknown")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { stats.refreshInk(queue: s.queue) }
            if !stats.hasAutoLevels {
                Button("Enter levels…") { showLevels = true }
            }
        }
    }

    // MARK: Ink

    private var inkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Ink")
            if !stats.hasAutoLevels {
                Text("Could not read ink levels from the printer. Check that it is on and on the network, then press Refresh. You can also type levels in from System Settings > Printers & Scanners > Supply Levels with Enter levels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let rows = stats.channelStats()
            VStack(spacing: 8) {
                ForEach(rows) { r in inkRow(r) }
            }
            if let last = stats.snapshots.last {
                Text("Updated \(last.date.formatted(date: .abbreviated, time: .shortened)) (\(last.source == "cups" ? "read from the printer" : "typed in"))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No levels recorded yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func inkRow(_ r: ChannelStat) -> some View {
        let c = Ink.display[r.id]
        let color = Color(red: c.0, green: c.1, blue: c.2)
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1))
            Text(r.name).frame(width: 140, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                        .frame(width: g.size.width * CGFloat(max(0, min(100, r.level ?? 0))) / 100)
                }
            }
            .frame(height: 10)
            Text(r.level.map { "\($0)%" } ?? "n/a")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            Text(detail(r))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 230, alignment: .leading)
                .lineLimit(2)
        }
    }

    private func detail(_ r: ChannelStat) -> String {
        guard r.level != nil else { return "" }
        if r.prints > 0 {
            let n = r.prints == 1 ? "1 print" : "\(r.prints) prints"
            let used = r.usedPoints >= 1 ? "\(Int(r.usedPoints))% used" : "under 1% used"
            var t = "\(n), \(used)"
            if let left = r.sheetsLeft {
                t += ", about \(Int(left.rounded())) 13×19 left"
            }
            return t
        }
        if let d = r.since {
            return "tracking since \(d.formatted(date: .abbreviated, time: .omitted))"
        }
        return ""
    }

    // MARK: Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Printing")
            HStack(spacing: 12) {
                tile("Prints", "\(stats.totalPrints)")
                tile("Last 30 days", "\(stats.printsLast30Days)")
                tile("Paper used", String(format: "%.1f sq ft", stats.totalSqFt))
                tile("Black ink switches", "\(stats.blackSwitches)")
            }
            if stats.blackSwitches > 0 {
                Text("Going between Matte Black and Photo Black papers makes the printer swap and purge ink. Batching prints by paper type saves ink.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(s.palette.tile))
    }

    // MARK: Breakdown

    private var breakdownSection: some View {
        HStack(alignment: .top, spacing: 24) {
            breakdown("By paper", Array(stats.counts { $0.paper }.prefix(8)))
            breakdown("By sheet", stats.counts { sheetLabel($0.sheetID) })
            breakdown("Black ink", stats.counts { $0.blackInk })
        }
    }

    private func sheetLabel(_ id: String) -> String {
        SheetSize.all.first(where: { $0.id == id })?.label ?? id
    }

    private func breakdown(_ title: String, _ rows: [(String, Int)]) -> some View {
        let maxV = max(rows.map { $0.1 }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            if rows.isEmpty {
                Text("Nothing yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(rows[i].0).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(rows[i].1)").font(.caption).monospacedDigit()
                    }
                    GeometryReader { g in
                        Capsule().fill(s.palette.accent.opacity(0.7))
                            .frame(width: g.size.width * CGFloat(rows[i].1) / CGFloat(maxV))
                    }
                    .frame(height: 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Print history")
                Spacer()
                Button("Open history folder") { stats.openHistoryFolder() }
            }
            let all = stats.records.sorted { $0.date > $1.date }
            if all.isEmpty {
                Text("Every print you send from this app is saved here with a copy of the file, a thumbnail and the settings you used. The copies live in Pictures, in a folder called P900 Print History.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(all.prefix(recentCount))) { r in
                HistoryRow(record: r)
                Divider()
            }
            if !all.isEmpty {
                Button(all.count > recentCount ? "All prints (\(all.count))" : "Open in a separate window") {
                    openWindow(id: "all-prints")
                }
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

// MARK: - Manual levels

struct LevelsSheet: View {
    @ObservedObject var stats: PrintStats
    let queue: String
    @Environment(\.dismiss) private var dismiss
    @State private var values: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ink levels").font(.title3.weight(.semibold))
            Text("Copy these from System Settings > Printers & Scanners > your printer > Options & Supplies > Supply Levels. Leave a cartridge at 0 if it is empty.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(0..<Ink.names.count, id: \.self) { i in
                HStack {
                    let c = Ink.display[i]
                    Circle().fill(Color(red: c.0, green: c.1, blue: c.2)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1))
                    Text(Ink.names[i]).frame(width: 150, alignment: .leading)
                    TextField("", value: binding(i), format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("%")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    stats.addManual(levels: values, queue: queue)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            let last = stats.latestLevels
            values = last.map { max(0, $0) }
        }
    }

    private func binding(_ i: Int) -> Binding<Int> {
        Binding(get: { i < values.count ? values[i] : 0 },
                set: { if i < values.count { values[i] = max(0, min(100, $0)) } })
    }
}

// MARK: - History row

struct HistoryRow: View {
    @EnvironmentObject var s: AppState
    @ObservedObject var stats = PrintStats.shared
    let record: PrintRecord
    /// Runs after Print again, so a second window can bring the main window forward.
    var afterReprint: (() -> Void)? = nil
    @State private var thumb: NSImage?
    @State private var confirmRemove = false

    private var sheetLabel: String {
        SheetSize.all.first(where: { $0.id == record.sheetID })?.label ?? record.sheetID
    }

    private var sourceURL: URL? {
        guard let f = record.folder, let n = record.sourceName else { return nil }
        let u = URL(fileURLWithPath: f).appendingPathComponent(n)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
                if let t = thumb {
                    Image(nsImage: t).resizable().scaledToFit()
                }
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(record.paper), \(sheetLabel), \(record.copies == 1 ? "1 copy" : "\(record.copies) copies")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let u = sourceURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                Button("Print again") { s.reprint(record); afterReprint?() }
            }
            Button("Remove") { confirmRemove = true }
                .confirmationDialog("Remove \"\(record.title)\" from history?",
                                    isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { stats.deleteRecord(record.id) }
                } message: {
                    Text("Use this for a job that never printed. It also drops it from the print counts and moves its saved copy to the Trash.")
                }
        }
        .onAppear {
            if thumb == nil, let f = record.folder {
                thumb = NSImage(contentsOf: URL(fileURLWithPath: f).appendingPathComponent("thumb.jpg"))
            }
        }
    }
}

// MARK: - All prints window

struct MonthGroup: Identifiable {
    let id: String
    let records: [PrintRecord]
}

/// Every print ever sent, newest first, grouped by month, with a search box.
struct AllPrintsView: View {
    @EnvironmentObject var s: AppState
    @ObservedObject var stats = PrintStats.shared
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private func sheetLabel(_ id: String) -> String {
        SheetSize.all.first(where: { $0.id == id })?.label ?? id
    }

    private var filtered: [PrintRecord] {
        let all = stats.records.sorted { $0.date > $1.date }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { r in
            r.title.lowercased().contains(q)
                || r.paper.lowercased().contains(q)
                || sheetLabel(r.sheetID).lowercased().contains(q)
        }
    }

    private var months: [MonthGroup] {
        var order: [String] = []
        var buckets: [String: [PrintRecord]] = [:]
        for r in filtered {
            let key = r.date.formatted(.dateTime.month(.wide).year())
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(r)
        }
        return order.map { MonthGroup(id: $0, records: buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search title, paper or sheet", text: $query)
                    .textFieldStyle(.roundedBorder)
                Text("\(filtered.count) of \(stats.records.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Open history folder") { stats.openHistoryFolder() }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(months) { m in
                        Section {
                            ForEach(m.records) { r in
                                HistoryRow(record: r, afterReprint: { openWindow(id: "main") })
                                    .padding(.vertical, 6)
                                Divider()
                            }
                        } header: {
                            Text(m.id.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .background(s.palette.pane)
                        }
                    }
                    if filtered.isEmpty {
                        Text(stats.records.isEmpty ? "No prints yet." : "No prints match.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(s.palette.pane)
        .fontDesign(.monospaced)
        .tint(s.palette.accent)
        .preferredColorScheme(.dark)
    }
}
