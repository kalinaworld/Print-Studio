import SwiftUI

enum PrinterPhase { case unknown, idle, waiting, printing, offline }

struct QueuedJob: Identifiable {
    let id: String          // e.g. EPSON_SC_P900_Series-2146
    let user: String
    let bytes: Int
    let created: Date?
}

/// Watches the Mac's print queue (cupsd, local only). It never talks to the printer over USB.
final class PrinterMonitor: ObservableObject {
    static let shared = PrinterMonitor()

    @Published var phase: PrinterPhase = .unknown
    @Published var jobs: [QueuedJob] = []
    @Published var detail = ""
    private var busy = false

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    func refresh(queue: String) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pOut = InkReader.shell("/usr/bin/lpstat", ["-p", queue, "-l"]) ?? ""
            let oOut = InkReader.shell("/usr/bin/lpstat", ["-o", queue]) ?? ""
            let low = pOut.lowercased()

            var jobs: [QueuedJob] = []
            for raw in oOut.split(separator: "\n") {
                let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 3, parts[0].hasPrefix(queue) else { continue }
                let dateText = parts.dropFirst(3).joined(separator: " ")
                jobs.append(QueuedJob(id: parts[0], user: parts[1], bytes: Int(parts[2]) ?? 0,
                                      created: Self.dateFormat.date(from: dateText)))
            }

            var phase: PrinterPhase
            var detail = ""
            if pOut.isEmpty {
                phase = .unknown
            } else if low.contains("offline") || low.contains("disabled") || low.contains("paused") {
                phase = .offline
                detail = pOut.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { let l = $0.lowercased(); return l.contains("offline") || l.contains("paused") || l.contains("disabled") } ?? ""
            } else if low.contains("now printing") {
                phase = .printing
            } else if !jobs.isEmpty {
                phase = .waiting
            } else {
                phase = .idle
            }

            DispatchQueue.main.async {
                self?.phase = phase
                self?.jobs = jobs
                self?.detail = detail
                self?.busy = false
            }
        }
    }
}

/// Compact printer status for the top right of the window. Shown while a job is printing, waiting, or the printer is offline.
struct StatusPill: View {
    @EnvironmentObject var s: AppState
    @ObservedObject var mon = PrinterMonitor.shared
    @ObservedObject var stats = PrintStats.shared
    @State private var now = Date()

    private var color: Color {
        switch mon.phase {
        case .idle: return Color(hex: 0x4CAF6A)
        case .printing: return Color(hex: 0x4DA3FF)
        case .waiting, .unknown: return Color.secondary
        case .offline: return s.palette.accent
        }
    }

    private var label: String {
        switch mon.phase {
        case .unknown: return "Printer status unknown"
        case .idle: return "Printer idle"
        case .waiting: return mon.jobs.count == 1 ? "1 job waiting" : "\(mon.jobs.count) jobs waiting"
        case .printing: return "Printing"
        case .offline: return "Printer offline"
        }
    }

    private func title(_ j: QueuedJob) -> String {
        stats.records.first { $0.jobID == j.id }?.title ?? j.id
    }

    private func elapsed(_ j: QueuedJob) -> String {
        guard let c = j.created else { return "" }
        let t = max(0, Int(now.timeIntervalSince(c)))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(mon.phase == .offline ? s.palette.accent : Color.primary)
            if let j = mon.jobs.first {
                Text(title(j))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140)
                Text(elapsed(j)).monospacedDigit().foregroundStyle(.secondary)
                if mon.jobs.count > 1 {
                    Text("+\(mon.jobs.count - 1)").foregroundStyle(.secondary)
                }
            }
            if !mon.jobs.isEmpty {
                Button("Cancel") { s.cancelAllJobs() }
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .help(mon.phase == .offline ? "Check power and the network cable, or switch it off and on again." : "Printer status")
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { t in
            now = t
        }
    }
}
