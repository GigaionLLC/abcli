// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Why a sync did not do what the administrator asked — reduced to ONE line they can act on,
/// with the complete text kept alongside it.
///
/// The bug this type exists to kill: abgui used to hand the view `error.localizedDescription`,
/// which for a failed `sync --apply` is abctl's WHOLE stderr — a hundred lines of "building
/// plan: …" narration with the actual cause buried somewhere inside (or, when abctl exits via
/// `cli.ExitError`, not present at all, because `cmd/abctl/main.go` exits SILENTLY for that
/// case). The user's complaint was exactly that: they had to read the log blob to find out
/// whether the sync even failed.
///
/// So the contract here is *ranking, never discarding*: `headline` is the best short summary
/// this code can justify, and `details` is everything it was derived from. Every rule below
/// degrades toward showing more, because losing the cause is the failure mode we are fixing.
struct SyncFailure: Equatable, Identifiable, Sendable {
    /// What kind of failure this is — the shape of the fix, not the shape of the message.
    /// A view can pick an icon or an explanation from this; nothing branches on the text.
    enum Kind: String, Equatable, Sendable {
        /// abctl ran the plan and Apple (or the tree) rejected individual items. The
        /// authoritative per-item detail came back on stdout as `status:"error"` rows.
        case itemsFailed
        /// abctl never got as far as applying — bad credentials, no `gitops/` tree, an Apple
        /// 403 while building the plan. stdout is empty; stderr is all we have.
        case aborted
        /// abgui's own watchdog stopped the child (not an abctl exit code).
        case timedOut
        /// The user cancelled. Not a fault, but the tenant is in a half-applied state, so it
        /// is still reported rather than silently swallowed.
        case cancelled
        /// abctl exited 0 but its stdout did not decode — a version skew between the app and
        /// the embedded CLI.
        case unreadable
        /// Every applied item reported `done` and abctl STILL exited non-zero. Today that means
        /// post-apply verification re-read the writes and found Apple had not persisted them
        /// (`internal/cli/phase1.go` → `finishApply`); the verdict is on stderr, not in the rows.
        case exitedNonZero
    }

    var kind: Kind
    /// One line, whitespace-collapsed and truncated. Safe to put in a title or a banner.
    var headline: String
    /// Everything the headline was derived from, verbatim and untruncated. Never empty when
    /// there was anything at all to show.
    var details: String

    /// Content-derived so an unchanged failure keeps its identity across re-renders (and two
    /// genuinely different failures never collide in a `.sheet(item:)`).
    var id: String { "\(kind.rawValue)|\(headline)|\(details.count)" }

    /// The one blob a "Copy error" button should put on the pasteboard: the summary the user
    /// is looking at, then the evidence under it. (Copying the *run log* is a separate,
    /// bigger thing — see `RunLog` and `AppModel.lastRunLogURL`.)
    var copyableText: String {
        details.isEmpty ? headline : "\(headline)\n\n\(details)"
    }

    // MARK: the three ways a sync fails — items rejected, a non-zero exit despite clean
    // items (post-apply verification), and an abort with no result document at all.

    /// The COMMON case now that `AbctlClient.syncApply` decodes before it checks the exit code:
    /// abctl applied the plan and some items came back `status:"error"`, each with a detail
    /// naming what Apple refused. Returns nil ONLY for a run that both reported every item done
    /// AND exited 0 — this is the caller's whole pass/fail test, so there is no second condition
    /// that could disagree with it.
    static func from(applyResult: ApplyResult, exitCode: Int32 = 0, stderr: String = "",
                     transcript: [String] = []) -> SyncFailure? {
        let failed = applyResult.rows.filter(\.failed)
        guard !failed.isEmpty else {
            // The counters and the rows are incremented together by the reconcile engine, so
            // they cannot normally disagree — but if a future abctl reports errors without rows,
            // "no rows" must not be read as "clean".
            if applyResult.totalErrors > 0 {
                return SyncFailure(kind: .itemsFailed,
                                   headline: "abctl reported \(applyResult.totalErrors) error(s) without saying which items failed.",
                                   details: "writes: \(applyResult.totalWrites), errors: \(applyResult.totalErrors), skipped: \(applyResult.totalSkipped)")
            }
            guard exitCode != 0 else { return nil }
            return fromNonZeroExit(code: exitCode, stderr: stderr, transcript: transcript)
        }
        let first = describe(failed[0])
        let headline: String
        if failed.count == 1 {
            headline = "1 change failed — \(first)"
        } else {
            headline = "\(failed.count) of \(applyResult.rows.count) changes failed — first: \(first)"
        }
        // A run can fail items AND fail the read-back; the rows are the headline, but the
        // verdict lines are appended so the second problem isn't silently outranked.
        var details = failed.map(describe).joined(separator: "\n")
        let verdicts = verdictLines(stderr)
        if !verdicts.isEmpty { details += "\n\n" + verdicts.joined(separator: "\n") }
        return SyncFailure(kind: .itemsFailed, headline: shorten(headline), details: details)
    }

    /// abctl applied everything it was asked to, said every item was `done`, and STILL exited
    /// non-zero. Today that is post-apply verification: it re-reads the configs it just wrote and
    /// fails the run when Apple's stored bytes don't match git (Apple answers `2xx` to a PATCH it
    /// then silently drops). The verdict is only on stderr, so it has to be mined out — and the
    /// SUMMARY line of that report starts with the same `post-apply verification: ` prefix as the
    /// progress narration, which is why the explicit `FAILED` lines are looked at first.
    static func fromNonZeroExit(code: Int32, stderr: String, transcript: [String] = []) -> SyncFailure {
        let verdicts = verdictLines(stderr)
        let headline: String
        if verdicts.count > 1 {
            headline = shorten("\(verdicts.count) checks failed — \(verdicts[0])")
        } else if let only = verdicts.first {
            headline = shorten(only)
        } else if let extracted = extractHeadline(fromStderr: stderr) {
            headline = extracted
        } else {
            headline = "abctl applied the plan but exited \(code) — the tenant may not match git."
        }
        return SyncFailure(kind: .exitedNonZero, headline: headline, details: fallbackDetails(stderr, transcript))
    }

    /// Lines where abctl states a VERDICT rather than progress. `post-apply verification FAILED:`
    /// is the wording `internal/cli/phase1.go` prints (and that CI greps for), so the marker is
    /// the uppercase word rather than the prefix.
    static let verdictMarker = "FAILED"

    static func verdictLines(_ stderr: String) -> [String] {
        significantLines(stderr).filter { $0.contains(verdictMarker) }
    }

    /// The ABORT case: abctl exited without producing a result document, so the only evidence
    /// is stderr (plus, if that is empty too, whatever abgui already narrated). `transcript` is
    /// the apply progress log — used ONLY as a last resort, since it otherwise just repeats the
    /// same stderr lines back with abgui's own `$ …` lines mixed in.
    static func from(error: Error, transcript: [String] = []) -> SyncFailure {
        if error is CancellationError {
            return SyncFailure(kind: .cancelled,
                               headline: "Sync was cancelled before it finished.",
                               details: fallbackDetails("", transcript))
        }
        guard let abctl = error as? AbctlError else {
            // Anything else (a spawn failure, a Foundation error) already carries a short,
            // human message — there is no stderr to mine, so use it as-is.
            let text = error.localizedDescription
            return SyncFailure(kind: .aborted,
                               headline: shorten(text.isEmpty ? "Sync failed." : text),
                               details: fallbackDetails(text, transcript))
        }
        switch abctl {
        case .cli(let stderr):
            return aborted(stderr: stderr, transcript: transcript)
        case .usage(let stderr):
            // A non-0/non-1/non-3 exit means abgui built argv abctl did not understand: still
            // mine stderr (it usually names the bad flag), but say whose bug it is.
            let failure = aborted(stderr: stderr, transcript: transcript)
            return SyncFailure(kind: .aborted,
                               headline: "abctl rejected the command abgui built — \(failure.headline)",
                               details: failure.details)
        case .timedOut(let seconds, _):
            // The long "here is what a timeout usually means" paragraph is the DETAIL; the
            // headline just has to say the run was stopped and after how long.
            return SyncFailure(kind: .timedOut,
                               headline: "abctl ran for \(seconds)s without finishing and was stopped.",
                               details: fallbackDetails(abctl.errorDescription ?? "", transcript))
        case .decode(let underlying):
            return SyncFailure(kind: .unreadable,
                               headline: "abctl finished, but abgui could not read its result — the app and the embedded CLI may not match.",
                               details: fallbackDetails(underlying.localizedDescription, transcript))
        case .changesPending:
            // Exit 3 is a dry-run signal; reaching it from --apply means the flags were wrong.
            return SyncFailure(kind: .aborted,
                               headline: "abctl reported changes pending (exit 3) instead of applying them.",
                               details: fallbackDetails(abctl.errorDescription ?? "", transcript))
        }
    }

    private static func aborted(stderr: String, transcript: [String]) -> SyncFailure {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = text.isEmpty ? transcript.joined(separator: "\n") : text
        let headline = extractHeadline(fromStderr: source) ?? synthesizedHeadline(fromStderr: source)
        return SyncFailure(kind: .aborted, headline: headline, details: fallbackDetails(text, transcript))
    }

    // MARK: the extractor — PURE, so the rule can be tested against real captured stderr
    // without a process, a tenant or a UI (Tests/abguiTests).

    /// `cmd/abctl/main.go` prints `Error: <err>` to stderr for a plain error and exits SILENTLY
    /// for a `cli.ExitError` — so a marked line is NOT guaranteed and the rules have to fall
    /// through:
    ///
    /// 1. the LAST `Error: …` line (the outermost wrap, i.e. the most contextual sentence);
    /// 2. else the last line that is not abctl's progress narration (an unmarked abort such as
    ///    `aborted — no changes applied.` lands here);
    /// 3. else nil — the caller synthesizes one, and `details` still carries everything.
    ///
    /// Returns a condensed, truncated single line. `ab.APIError` can be ~500 characters of
    /// Apple's raw response body, which is why nothing here is used untruncated — and why the
    /// untruncated text is always kept in `details`.
    static func extractHeadline(fromStderr text: String) -> String? {
        let lines = significantLines(text)
        guard !lines.isEmpty else { return nil }
        if let marked = lines.last(where: { $0.hasPrefix(errorMarker) }) {
            let body = String(marked.dropFirst(errorMarker.count)).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { return shorten(body) }
        }
        if let meaningful = lines.last(where: { !isNarration($0) }) {
            return shorten(meaningful)
        }
        return nil
    }

    /// Rule 3: everything abctl printed was progress narration, so name WHERE it stopped rather
    /// than inventing a cause. Showing the last thing that happened beats a generic sentence,
    /// and the full text is one scroll away regardless.
    static func synthesizedHeadline(fromStderr text: String) -> String {
        guard let last = significantLines(text).last else {
            return "abctl stopped without applying the plan and printed no error."
        }
        return shorten("abctl stopped during: \(last)")
    }

    /// abctl's progress narration, by the prefixes it actually emits (`internal/cli/phase1.go`,
    /// `internal/reconcile/apply.go` + `blueprint.go`, `internal/ab/client.go`). These lines
    /// describe what abctl was DOING, never what went wrong, so they are never the headline.
    ///
    /// Deliberately a conservative allow-list of *verified* prefixes: a line wrongly classified
    /// as narration is a hidden cause, which is the bug being fixed here, whereas a line wrongly
    /// kept just makes the headline less pretty.
    static let narrationPrefixes: [String] = [
        "building plan: ",
        "post-apply verification: ",
        "applying config ",
        "applying blueprint ",
        "creating configuration in ABM: ",
        "creating blueprint in ABM: ",
        "deleting configuration from ABM: ",
        // The apply's own confirming read-back (`reconcile.push`) — narration, not a verdict.
        // Without it, a run that aborts during the read-back surfaces "verifying the stored
        // configuration in ABM: X" to the user as the CAUSE of the failure.
        "verifying the stored configuration in ABM: ",
        "attaching ",
        "detaching ",
        "archiving ",
        "patching ",
        "fetching ",
        "requesting ",
        "reusing cached ",
        "read CUSTOM_SETTING ",
        "writing live ",
        "removing git ",
        "$ abctl ",   // abgui's own transcript lines, when the transcript is the last resort
        "→ ",
    ]

    static func isNarration(_ line: String) -> Bool {
        narrationPrefixes.contains { line.hasPrefix($0) }
    }

    /// The marker `main.go` prints for a non-`ExitError` failure.
    static let errorMarker = "Error:"

    /// The headline budget. Long enough for a real Apple error sentence, short enough that a
    /// banner stays one or two lines.
    static let headlineLimit = 180

    // MARK: text plumbing

    private static func significantLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One line, whitespace collapsed (Apple's raw body arrives with embedded newlines) and cut
    /// at a word boundary. Truncation is safe here ONLY because `details` keeps the full text.
    static func shorten(_ text: String, limit: Int = SyncFailure.headlineLimit) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let head = flat.prefix(limit)
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return head[head.startIndex..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `details` is the authoritative text; the narrated transcript is only substituted when
    /// there is no authoritative text at all, because it otherwise duplicates the same stderr
    /// the view is already showing in the progress log.
    private static func fallbackDetails(_ text: String, _ transcript: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return transcript.joined(separator: "\n")
    }

    /// One failed apply row as a line: `update-abm WiFi-Corp.mobileconfig: 403 …`.
    private static func describe(_ row: OutcomeRow) -> String {
        let what = row.name.isEmpty ? row.action : "\(row.action) \(row.name)"
        return row.detail.isEmpty ? what : "\(what): \(row.detail)"
    }
}
