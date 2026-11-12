import Foundation

/// Watches ~/Library/Application Support/P900Print/Inbox for files the Photoshop script drops there.
final class InboxWatcher {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/P900Print/Inbox", isDirectory: true)
    }

    private var source: DispatchSourceFileSystemObject?
    private var lastLoaded = Date().addingTimeInterval(-90)   // pick up a file saved just before launch
    private var onNew: ((URL) -> Void)?
    private var pending = false

    func start(onNew: @escaping (URL) -> Void) {
        self.onNew = onNew
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let fd = open(Self.folder.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleCheck() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        scheduleCheck()
    }

    private func scheduleCheck() {
        if pending { return }
        pending = true
        let since = lastLoaded
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.check(since: since)
        }
    }

    private func check(since: Date) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.folder,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var newest: (url: URL, date: Date)?
        for f in files {
            let ext = f.pathExtension.lowercased()
            guard ["tif", "tiff", "png", "jpg", "jpeg"].contains(ext) else { continue }
            guard let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                continue
            }
            if Date().timeIntervalSince(d) > 86400 {
                try? fm.removeItem(at: f)
                continue
            }
            if d > since, newest == nil || d > newest!.date {
                newest = (f, d)
            }
        }
        guard let n = newest else {
            DispatchQueue.main.async { self.pending = false }
            return
        }

        // Wait until the file stops growing (Photoshop may still be writing it).
        var lastSize = -1
        var steady = 0
        for _ in 0..<400 {
            let size = (try? n.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 0 && size == lastSize {
                steady += 1
                if steady >= 2 { break }   // unchanged for about half a second
            } else {
                steady = 0
            }
            lastSize = size
            Thread.sleep(forTimeInterval: 0.25)
        }

        DispatchQueue.main.async {
            self.lastLoaded = n.date
            self.pending = false
            self.onNew?(n.url)
        }
    }
}
