import SwiftUI
import AppKit

@main
struct P900PrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    init() {
        // Command line self test, used by check_color_pipeline.py. Never opens a window.
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run(args: CommandLine.arguments))
        }
    }

    var body: some Scene {
        Window("Kalina Print Studio", id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Print") { state.newPrint() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Image…") { state.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print") { state.startPrint(dryRun: false) }
                    .keyboardShortcut("p", modifiers: .command)
            }
        }
        Window("All Prints", id: "all-prints") {
            AllPrintsView()
                .environmentObject(state)
        }
        .defaultSize(width: 780, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.startInbox()
        PrintStats.shared.refreshInk(queue: AppState.shared.queue)
        for arg in CommandLine.arguments.dropFirst() where FileManager.default.fileExists(atPath: arg) {
            AppState.shared.load(url: URL(fileURLWithPath: arg))
            break
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let u = urls.first { AppState.shared.load(url: u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
