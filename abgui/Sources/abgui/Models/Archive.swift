// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// One archived pre-overwrite live profile that abctl filed before an overwrite/delete,
/// under <workspace>/gitops/archive/<name>/<ts>--<reason>.mobileconfig (+ .json sidecar).
struct ArchiveEntry: Identifiable, Hashable {
    let configName: String   // the real config name (from the sidecar), for restore
    let reason: String
    let archivedAt: String   // RFC3339
    let fileURL: URL

    var id: String { fileURL.path }
}

/// The sidecar abctl writes next to each archived profile.
private struct ArchiveSidecar: Decodable {
    let name: String
    let reason: String
    let archivedAt: String
}

/// Reads the on-disk archive tree — pure filesystem, no abctl (there is no CLI command
/// to list the archive). Kept in the core so it is unit-testable against a temp tree.
enum ArchiveScanner {
    static func scan(root: URL) -> [ArchiveEntry] {
        let fm = FileManager.default
        let archiveRoot = root.appendingPathComponent("gitops/archive", isDirectory: true)
        guard let configDirs = try? fm.contentsOfDirectory(at: archiveRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var entries: [ArchiveEntry] = []
        for dir in configDirs {
            // Listing a stray file (e.g. .DS_Store) fails → skip; only real subdirs list.
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "mobileconfig" {
                let sidecarURL = file.deletingPathExtension().appendingPathExtension("json")
                var name = dir.lastPathComponent
                var reason = ""
                var archivedAt = ""
                if let data = try? Data(contentsOf: sidecarURL),
                   let side = try? JSONDecoder().decode(ArchiveSidecar.self, from: data) {
                    name = side.name
                    reason = side.reason
                    archivedAt = side.archivedAt
                }
                entries.append(ArchiveEntry(configName: name, reason: reason, archivedAt: archivedAt, fileURL: file))
            }
        }
        return entries.sorted { $0.archivedAt > $1.archivedAt } // newest first
    }
}
