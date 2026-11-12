import Foundation

extension URL {
    /// File name without extension, minus the "ps-<timestamp>-" prefix the Photoshop script adds.
    var displayName: String {
        let base = deletingPathExtension().lastPathComponent
        if let r = base.range(of: "^ps-[0-9]+-", options: .regularExpression) {
            let rest = String(base[r.upperBound...])
            return rest.isEmpty ? base : rest
        }
        return base
    }
}
