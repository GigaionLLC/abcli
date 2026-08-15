// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Timing rolled up per abctl verb, from the invocations abgui has already recorded.
///
/// Every command runs through the one `AbctlRunner.run` seam and is timed there
/// (`RecordingRunner` → `CommandRecord.duration`), so this needs no new instrumentation — the
/// numbers exist, they were just never added up. The chronological log answers "what did this
/// run do"; this answers the question that actually finds a performance bug: "which verb is
/// slow, is it slow EVERY time, and is one of them still running right now?"
struct CommandTiming: Identifiable, Equatable {
    /// The verb as a human would name it: `diff`, `get configurations`, `adopt config`.
    let verb: String
    var runs = 0
    var failures = 0
    var totalDuration: TimeInterval = 0
    var slowest: TimeInterval = 0
    /// Invocations of this verb that have not finished yet — the "is it still loading?" signal.
    var running = 0

    var id: String { verb }
    var average: TimeInterval { runs == 0 ? 0 : totalDuration / Double(runs) }

    /// Roll up finished AND in-flight records, slowest verb first. Ties break on name so the
    /// order is stable while a run is in flight and the list is re-rendering every second.
    static func rollUp(_ records: [CommandRecord]) -> [CommandTiming] {
        var byVerb: [String: CommandTiming] = [:]
        for record in records {
            let key = verbKey(record.argv)
            var entry = byVerb[key] ?? CommandTiming(verb: key)
            if record.status == .running {
                entry.running += 1
            } else if let duration = record.duration {
                entry.runs += 1
                entry.totalDuration += duration
                entry.slowest = max(entry.slowest, duration)
            }
            if record.isFailure { entry.failures += 1 }
            byVerb[key] = entry
        }
        return byVerb.values.sorted {
            $0.slowest == $1.slowest ? $0.verb < $1.verb : $0.slowest > $1.slowest
        }
    }

    /// The leading argv tokens that name the operation: the verb, plus its subject when there is
    /// one (`get configurations`, `adopt config`). Stops at the first flag, so `--json` and a
    /// tenant-specific `--blueprint <name>` never fragment one verb into many rows — the whole
    /// point is to compare repeated runs of the same operation against each other.
    static func verbKey(_ argv: [String]) -> String {
        let words = argv.prefix { !$0.hasPrefix("-") }.prefix(2)
        return words.isEmpty ? "abctl" : words.joined(separator: " ")
    }
}

extension CommandRecord {
    /// Wall-clock time this command has taken: its final duration once finished, else how long it
    /// has been running as of `now`. Feeding `now` in (rather than reading the clock here) is what
    /// lets a view tick this from a `TimelineView` and keeps it testable.
    func elapsed(asOf now: Date = Date()) -> TimeInterval {
        duration ?? max(0, now.timeIntervalSince(startedAt))
    }

    /// Long enough that a person notices the wait. Used only to draw attention in the log — it
    /// marks nothing as broken, and abgui's real limits are the per-verb timeouts in AbctlClient.
    static let slowThreshold: TimeInterval = 5

    func isSlow(asOf now: Date = Date()) -> Bool { elapsed(asOf: now) >= Self.slowThreshold }
}

/// Format a duration the same way everywhere it is shown.
enum DurationText {
    static func short(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            let whole = Int(seconds.rounded())
            return "\(whole / 60)m \(whole % 60)s"
        }
        return String(format: "%.1fs", seconds)
    }
}
