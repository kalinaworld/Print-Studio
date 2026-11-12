import SwiftUI
import AppKit

/// Everything the app has done this session, newest at the bottom. The technical detail that used to sit under Advanced.
struct LogView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Text("\(s.activity.count) lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.activity.joined(separator: "\n"), forType: .string)
                }
                .disabled(s.activity.isEmpty)
                Button("Clear") { s.activity.removeAll() }
                    .disabled(s.activity.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            if s.activity.isEmpty {
                Text("Nothing yet. Loads, prints and cancels will show up here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(s.activity.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(line.contains("  lp -d ") ? Color.secondary.opacity(0.7) : Color.primary.opacity(0.9))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                        .padding(16)
                    }
                    .onAppear { proxy.scrollTo(s.activity.count - 1, anchor: .bottom) }
                    .onChange(of: s.activity.count) { _ in
                        proxy.scrollTo(s.activity.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .background(s.palette.bg)
    }
}
