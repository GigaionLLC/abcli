// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// One run log on disk, as the Logs screen lists it.
///
/// The identity fields come from the FILENAME (`RunLog.fileName`), which encodes verb, UTC start
/// and a short run id — so listing fifty logs costs a directory read and no file opens. The
/// outcome and duration come from a bounded read of the file's TAIL, because `RunLog` writes them
/// as a footer: that is what lets the list say "failed" or "plan computed" without loading
/// megabytes of transcript for a row the user may never click.
struct RunLogFile: Identifiable, Equatable {
    let url: URL
    let verb: String
    /// Parsed from the filename stamp, which is UTC and therefore comparable across machines.
    let startedAt: Date?
    let modifiedAt: Date
    let sizeBytes: Int
    /// From the footer. nil means the file has no footer — the run was interrupted, or the app
    /// was killed mid-run, which is itself worth showing rather than hiding.
    let outcome: String?
    let duration: String?

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// A footerless log is an unfinished one: `RunLog.finish` is what writes the footer.
    var isUnfinished: Bool { outcome == nil }

    /// Matches how `AppModel` classifies a failed run, so the list agrees with the sheet that
    /// reported it. Deliberately substring-based: the outcome line is prose written by
    /// `loadPlan`/`seedWorkspace`/`applyPlan`, not an enum.
    var isFailure: Bool {
        guard let outcome else { return false }
        let lowered = outcome.lowercased()
        return lowered.hasPrefix("failed") || lowered.contains("error")
    }

    var sizeText: String {
        if sizeBytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(sizeBytes) / (1024 * 1024))
        }
        if sizeBytes >= 1024 { return "\(sizeBytes / 1024) KB" }
        return "\(sizeBytes) bytes"
    }
}

/// Reads `~/Library/Logs/abgui/` into `RunLogFile` rows. Pure filesystem — no abctl, no network,
/// no credentials — so the Logs screen works even when the tenant connection is broken, which is
/// exactly when someone needs it.
enum RunLogIndex {
    /// How much of the file's end to read looking for the footer. The footer is ~6 short lines;
    /// this is generous and still bounded, so a 5 MiB transcript costs the same as an empty one.
    static let footerProbeBytes = 2_048

    static func scan(directory: URL = RunLog.directory) -> [RunLogFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var out: [RunLogFile] = []
        for url in entries where RunLog.isRunLogName(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let footer = readFooter(url)
            out.append(RunLogFile(url: url,
                                  verb: verb(fromName: url.lastPathComponent),
                                  startedAt: startDate(fromName: url.lastPathComponent),
                                  modifiedAt: values?.contentModificationDate ?? .distantPast,
                                  sizeBytes: values?.fileSize ?? 0,
                                  outcome: footer.outcome,
                                  duration: footer.duration))
        }
        // Newest first: the log you want is almost always the one that just ran.
        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// `diff-20260813T204445Z-b37749.log` → `diff`. The name shape is guaranteed by
    /// `RunLog.isRunLogName`, which every caller here filters on first.
    static func verb(fromName name: String) -> String {
        String(name.dropLast(4).split(separator: "-", omittingEmptySubsequences: false).first ?? "run")
    }

    /// `…-20260813T204445Z-…` → the instant, in UTC. nil if the stamp doesn't parse, which the
    /// UI then falls back to file mtime for rather than inventing a date.
    static func startDate(fromName name: String) -> Date? {
        let parts = name.dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let stamp = String(parts[1])
        guard stamp.count == 16 else { return nil }
        func int(_ range: Range<Int>) -> Int? {
            let chars = Array(stamp)
            guard range.upperBound <= chars.count else { return nil }
            return Int(String(chars[range]))
        }
        guard let year = int(0..<4), let month = int(4..<6), let day = int(6..<8),
              let hour = int(9..<11), let minute = int(11..<13), let second = int(13..<15) else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var calendar = Calendar(identifier: .gregorian)
        if let zone = TimeZone(identifier: "UTC") { calendar.timeZone = zone }
        return calendar.date(from: components)
    }

    /// Pull `outcome:` / `duration:` out of the file's tail. Reading only the end is the point:
    /// the list shows the verdict for every log without opening any of them fully.
    static func readFooter(_ url: URL) -> (outcome: String?, duration: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return (nil, nil) }
        let start = end > UInt64(footerProbeBytes) ? end - UInt64(footerProbeBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        var outcome: String?
        var duration: String?
        // Last occurrence wins: the probe window can clip into transcript text that happens to
        // contain the same words, and the real footer is always last.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("outcome: ") { outcome = String(line.dropFirst("outcome: ".count)) }
            if line.hasPrefix("duration: ") { duration = String(line.dropFirst("duration: ".count)) }
        }
        return (outcome, duration)
    }

    /// Read a whole log for display. Bounded by `RunLog.maxFileBytes` on the write side, so this
    /// cannot be handed something unbounded; a decode failure returns nil rather than garbage.
    static func contents(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
