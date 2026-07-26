// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// One run's transcript, on disk. A sync that fails at 2:00 a.m. is worth nothing if the only
/// copy of the evidence is a scroll view the user closes; this writes the same narration to a
/// file the app can hand to a support ticket by path.
///
/// **Location:** `~/Library/Logs/abgui/` — the macOS convention (Console.app shows it), and
/// deliberately NOT inside the user's GitOps workspace: abgui does not own that repo's
/// `.gitignore`, so writing logs there would eventually commit tenant identifiers.
///
/// **What a log may contain.** Everything abctl prints on stderr plus abgui's own transcript
/// lines. That means TENANT IDENTIFIERS — context/organization names, configuration and
/// blueprint names, device serials, Apple resource ids — and up to a few hundred bytes of
/// Apple's raw error-response body (`ab.APIError`). It does NOT contain credentials: the argv
/// in the header is `CommandRecord`'s redacted form (never the raw args), key material is never
/// on argv in the first place (contexts pass a key *path*), the one verb that prints a bearer
/// token (`auth token --raw`) writes it to stdout and abgui has no client method for it, and
/// profile XML fed on stdin is recorded as a byte count only. Files are `0600` inside a `0700`
/// directory for the same reason `CredentialStore` is.
///
/// **It cannot break a sync.** The public API cannot throw: `begin` returns nil if anything at
/// all goes wrong (no directory, read-only disk, sandbox denial), `line(_:)` is fire-and-forget
/// and costs an array append under a lock — no syscall and no main-actor hop, so a 2,000-line
/// run does not spend 2,000 hops on logging — and a failed write quietly retires the log rather
/// than propagating. Logging is a nice-to-have; applying the plan is not.
actor RunLog {
    /// The abctl operations abgui narrates. The raw value is BOTH the filename prefix and the
    /// pruner's match token, so adding a verb is one case here and nothing else.
    ///
    /// Only verbs that actually OPEN a log belong here: the pruner deletes what `isRunLogName`
    /// matches, and a case nothing writes has it claiming filenames on behalf of a file that
    /// never exists. `validate` is deliberately absent — `AppModel.validateProfiles()` runs a
    /// silent client (no stderr narration is streamed anywhere), so its log would be a header
    /// and a footer around nothing, and opening one would repoint `lastRunLogURL` away from the
    /// sync whose failure ApplySheet is still reporting. Add the case together with the
    /// `beginRunLog`/`finishRunLog` calls and a narrating client, never before.
    enum Verb: String, Sendable, CaseIterable {
        case sync, diff, seed
    }

    /// The self-describing header. Everything needed to reproduce the run, supplied by the
    /// caller because only `AppModel` knows the connection and the workspace.
    struct Header: Sendable {
        var verb: Verb
        /// The REDACTED command line — `CommandRecord.commandLine`, never raw argv. The type
        /// is `String` precisely so a caller cannot hand this an unredacted `[String]`.
        var command: String
        var workspace: URL? = nil
        var context: String? = nil
        var abctlVersion: String? = nil
        var abctlCommit: String? = nil
        /// Only the SIZE of anything piped in; content is never written.
        var stdin: CommandRecord.Stdin = .none
    }

    /// Bumped when the header/footer layout changes, so a parser (or a human) can tell which
    /// shape they are reading.
    static let schemaVersion = 1

    // Retention: at most this many files, none older than this, no more than this on disk in
    // total — whichever bites first, oldest deleted first. One file is capped as well, so a
    // pathological run cannot eat the budget by itself.
    static let maxFiles = 50
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    static let maxTotalBytes = 20 * 1024 * 1024
    static let maxFileBytes = 5 * 1024 * 1024
    static let truncationMarker = "[log truncated]\n"

    /// `~/Library/Logs/abgui`
    static var directory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return base.appendingPathComponent("Logs/abgui", isDirectory: true)
    }

    /// Where this run is being written. `nonisolated` so the UI can show and copy the path
    /// without awaiting the actor.
    nonisolated let url: URL

    /// The hand-off buffer. `nonisolated` is the whole point: `line(_:)` must not await.
    private nonisolated let buffer = LineBuffer()

    private let startedAt: Date
    private var handle: FileHandle?
    private var bytesWritten = 0
    private var linesWritten = 0
    private var droppedLines = 0
    private var truncated = false
    private var closed = false

    private init(startedAt: Date, url: URL) {
        self.startedAt = startedAt
        self.url = url
    }

    /// Open a log for this run, or return nil if it cannot be created. `nil` is a perfectly
    /// normal outcome — callers hold a `RunLog?` and use optional chaining, so a machine that
    /// cannot write logs simply runs without them.
    static func begin(_ header: Header, at date: Date = Date(), runID: UUID = UUID()) async -> RunLog? {
        let url = directory.appendingPathComponent(fileName(verb: header.verb, started: date, runID: runID))
        let log = RunLog(startedAt: date, url: url)
        // `open` is actor-isolated, so the file I/O below happens on the actor's executor —
        // never on the main actor that called this.
        let opened = await log.open(header)
        return opened ? log : nil
    }

    /// Record one line. Fire-and-forget by contract: no `await`, no throw, no result. Ordering
    /// is preserved by the buffer, not by task scheduling (unstructured tasks reach an actor in
    /// no defined order, which would scramble a transcript).
    nonisolated func line(_ text: String) {
        guard buffer.enqueue(text) else { return } // a drain is already scheduled
        Task { await self.flush() }
    }

    /// Write the outcome footer and close. Safe to call twice; safe to never call (the file
    /// then simply has no footer, which is itself the signal that the app died mid-run).
    func finish(outcome: String, at date: Date = Date()) {
        flush()
        write(Self.footerText(outcome: outcome, startedAt: startedAt, finishedAt: date,
                              lines: linesWritten, dropped: droppedLines, truncated: truncated))
        try? handle?.close()
        handle = nil
        closed = true
        // Pruning touches the whole directory, so it happens off this run's critical path and
        // off the main actor entirely. Best-effort: a failure here is not a failure of anything.
        let keep = url
        Task.detached(priority: .utility) { RunLog.prune(excluding: keep) }
    }

    // MARK: file plumbing (all isolated — the only code that touches the handle)

    private func open(_ header: Header) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // `attributes` only apply to a directory this call CREATES: an existing
            // ~/Library/Logs/abgui (an earlier build, another tool, a looser umask) keeps
            // whatever mode it has and the call still succeeds. Assert the mode unconditionally
            // — cheap, idempotent, and it is what makes the 0700 promise above true. The listing
            // itself is sensitive: it enumerates which tenant operations ran and when.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.directory.path)
            // Create with 0600 up front rather than tightening afterwards, so the file is never
            // world-readable even for an instant.
            guard fm.createFile(atPath: url.path, contents: nil,
                                attributes: [.posixPermissions: 0o600]) else { return false }
            handle = try FileHandle(forWritingTo: url)
        } catch {
            return false
        }
        write(Self.headerText(header, startedAt: startedAt))
        return handle != nil
    }

    /// Drain the buffer into the file. Deliberately has NO `await` in its body: actor
    /// reentrancy therefore cannot interleave two drains and reorder the transcript.
    private func flush() {
        let pending = buffer.drain()
        guard !pending.isEmpty, !closed else { return } // drained regardless, so memory is freed
        var chunk = ""
        for text in pending {
            if truncated {
                droppedLines += 1
                continue
            }
            if bytesWritten + chunk.utf8.count + text.utf8.count + 1 > Self.maxFileBytes {
                chunk += Self.truncationMarker
                truncated = true
                droppedLines += 1
                continue
            }
            chunk += text + "\n"
            linesWritten += 1
        }
        write(chunk)
    }

    /// The one write path. A failed write retires the log instead of throwing: there is no
    /// caller who could do anything useful with the error, and a sync must not care.
    private func write(_ text: String) {
        guard !closed, let handle, !text.isEmpty, let data = text.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            try? handle.close()
            self.handle = nil
            closed = true
        }
    }

    // MARK: text (pure + static, so the layout is testable without a filesystem)

    static func headerText(_ header: Header, startedAt: Date) -> String {
        // Blank means "abctl resolves its own current context" — say that, rather than printing
        // an empty field a reader would have to guess about.
        let contextName = header.context.map { $0.isEmpty ? "(abctl default)" : $0 } ?? "(abctl default)"
        var out = ["# abgui run log",
                   "schema: \(schemaVersion)",
                   "verb: \(header.verb.rawValue)",
                   "started: \(isoUTC(startedAt))",
                   "abgui: \(abguiVersion)",
                   "abctl: \(abctlDescription(version: header.abctlVersion, commit: header.abctlCommit))",
                   "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                   "context: \(contextName)",
                   "workspace: \(header.workspace?.path ?? "(none)")",
                   "command: \(header.command)"]
        switch header.stdin {
        case .none:
            break
        case .profile(let bytes):
            // The SIZE, never the content — a profile can carry anything the admin put in it.
            out.append("stdin: profile on stdin (\(bytes) bytes)")
        }
        out.append(contentsOf: [
            "#",
            "# Everything below is abctl's stderr plus abgui's own transcript lines. It can",
            "# contain tenant identifiers (organization/context names, configuration and",
            "# blueprint names, device serials, Apple resource ids) and Apple's raw error",
            "# response body. It contains no credentials: the command above is the redacted",
            "# form, and anything piped in is recorded as a byte count only.",
            "# The outcome and duration are written as a footer at the END of this file.",
            "---",
            "",
        ])
        return out.joined(separator: "\n")
    }

    static func footerText(outcome: String, startedAt: Date, finishedAt: Date,
                           lines: Int, dropped: Int, truncated: Bool) -> String {
        var out = ["",
                   "---",
                   "finished: \(isoUTC(finishedAt))",
                   "duration: \(durationText(finishedAt.timeIntervalSince(startedAt)))",
                   "outcome: \(SyncFailure.shorten(outcome, limit: 400))",
                   "lines: \(lines)"]
        if truncated || dropped > 0 {
            out.append("dropped: \(dropped) line(s) — this run exceeded the \(maxFileBytes / (1024 * 1024)) MiB per-file cap")
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    /// The app's marketing version. A `swift run` dev build has no Info.plist, which is worth
    /// saying out loud in a log someone may be comparing against a release.
    static var abguiVersion: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let value, !value.isEmpty else { return "unknown (unbundled build)" }
        return value
    }

    static func abctlDescription(version: String?, commit: String?) -> String {
        guard let version, !version.isEmpty else { return "unknown (not connected yet)" }
        guard let commit, !commit.isEmpty else { return version }
        return "\(version) (\(commit))"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped >= 60 {
            let whole = Int(clamped.rounded())
            return "\(whole / 60)m \(whole % 60)s"
        }
        return String(format: "%.1fs", clamped)
    }

    // MARK: naming + retention

    static func fileName(verb: Verb, started: Date, runID: UUID) -> String {
        "\(verb.rawValue)-\(compactUTC(started))-\(shortID(runID)).log"
    }

    /// First 6 hex of the run's UUID: enough to tell apart two runs that started in the same
    /// second, short enough to read out over a support call.
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }

    /// `20260725T143005Z` — sorts lexicographically, is filename-safe, and is UTC so logs from
    /// two machines (or across a DST change) still line up.
    static func compactUTC(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func isoUTC(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Hand-rolled from `Calendar` rather than a `DateFormatter`: a value type, no locale to
    /// get wrong, and no shared-mutable-formatter question in a concurrent context.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        if let zone = TimeZone(identifier: "UTC") { calendar.timeZone = zone }
        return calendar
    }()

    /// Enforce the retention budget, oldest first. Best-effort and completely silent.
    static func prune(excluding keep: URL? = nil, now: Date = Date()) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, date: Date, size: Int)] = []
        for url in entries where isRunLogName(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            files.append((url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
        }
        files.sort { $0.date > $1.date } // newest first, so "keep the newest N" is a prefix
        let cutoff = now.addingTimeInterval(-maxAge)
        var running = 0
        for (index, file) in files.enumerated() {
            running += file.size
            let overCount = index >= maxFiles
            let tooOld = file.date < cutoff
            let overBudget = running > maxTotalBytes
            guard overCount || tooOld || overBudget else { continue }
            if let keep, file.url.path == keep.path { continue } // never the run that just wrote
            try? fm.removeItem(at: file.url)
        }
    }

    /// Matches ONLY the `<verb>-<UTC timestamp>-<6 hex>.log` names this type writes. The pruner
    /// DELETES, so it recognizes abgui's own shape and nothing else — whatever else a user or
    /// another tool parked in that folder is not ours to remove.
    static func isRunLogName(_ name: String) -> Bool {
        guard name.hasSuffix(".log") else { return false }
        let parts = name.dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, Verb(rawValue: String(parts[0])) != nil else { return false }
        let stamp = parts[1]
        guard stamp.count == 16, stamp.hasSuffix("Z") else { return false }
        for (offset, ch) in stamp.dropLast().enumerated() {
            if offset == 8 {
                guard ch == "T" else { return false }
            } else if !(ch.isASCII && ch.isNumber) {
                return false
            }
        }
        let hex = parts[2]
        return hex.count == 6 && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// The hand-off between whoever produced a line and the actor that writes it: a lock-protected
/// array, so `RunLog.line(_:)` costs an append — no syscall, no actor hop, no `await` at the
/// callsite. It is also what keeps the transcript IN ORDER, since unstructured tasks enqueued
/// onto an actor have no defined ordering between them.
private final class LineBuffer: @unchecked Sendable {
    /// A ceiling on unflushed lines, in case a producer somehow outruns the writer. Dropping
    /// the overflow beats growing without bound inside a process that is mid-sync.
    private static let cap = 20_000

    private let lock = NSLock()
    private var pending: [String] = []
    private var drainScheduled = false

    /// Returns true when the caller should schedule a drain — at most one is ever in flight,
    /// which is what keeps a 2,000-line run from spawning 2,000 tasks.
    func enqueue(_ line: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending.count < Self.cap { pending.append(line) }
        if drainScheduled { return false }
        drainScheduled = true
        return true
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        drainScheduled = false
        return out
    }
}
