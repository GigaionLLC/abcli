// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The gated converge: `sync --apply`. Shows the applicable pending count, exposes
/// `--prune` and `--limit-writes`, streams progress, and keeps final outcomes in a
/// separate pane. The Apply button IS the human gate.
struct ApplySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var prune = true
    @State private var limitText = ""
    @State private var showValidate = false
    @State private var confirmUnverifiedApply = false
    /// Owned HERE rather than inside the transcript because growing the log has to grow the SHEET
    /// too — a taller pane inside a fixed-height sheet just squeezes the controls above it.
    @State private var logExpanded = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            NoticeBanner() // flipping the source-of-truth mode from inside this sheet says so
            header

            Divider()

            // Above the ScrollView, never inside it: the outcome of a tenant write must not be a
            // thing you can scroll off screen. The old failure indication was an 11pt red caption
            // as the LAST child of this scrolling stack — below a log pane that had just grown by
            // fifty lines — so the one screen that changes Apple Business could report a total
            // failure somewhere the reader never looked.
            verdictBanner

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let plan = model.plan {
                        Text(applySummary(plan))
                            .foregroundStyle(.secondary)
                    }

                    // The confirm-gated switch: it shows ON/OFF, explains what the flip means
                    // before it happens, and (inline layout) spells out the current mode. The
                    // callback keeps today's rule that git-as-truth forces prune on — desired
                    // state without deletes/detaches would only ever be half-applied.
                    GitSourceOfTruthControl(layout: .inline) { enabled in
                        if enabled { prune = true }
                    }
                    Toggle("Allow deletes / detaches (--prune)", isOn: $prune)
                        .disabled(model.gitSourceOfTruth)

                    verificationRow

                    DisclosureGroup("Advanced sync behavior") {
                        Picker("Refresh", selection: $model.refreshMode) {
                            Text("Smart").tag("smart")
                            Text("Full Apple refresh").tag("full")
                            Text("Metadata/cache only").tag("metadata-only")
                        }
                        Picker("Verify", selection: $model.verifyMode) {
                            Text("Targeted").tag("targeted")
                            Text("Full").tag("full")
                            Text("None").tag("none")
                        }
                    }
                    HStack {
                        Text("Limit writes")
                        TextField("unlimited", text: $limitText)
                            .frame(width: 90)
                            .textFieldStyle(.roundedBorder)
                        Text("(circuit breaker)").foregroundStyle(.secondary).font(.caption)
                    }

                    if model.isWriting || !model.applyProgressLog.isEmpty {
                        // 460 rather than the default: the sheet grows with it (see the frame
                        // below), and a pane taller than the window it lives in would just push
                        // the outer scroll back into the picture this is meant to get rid of.
                        TranscriptView(title: "Progress",
                                       lines: model.applyProgressLog,
                                       logURL: model.lastRunLogURL,
                                       expandedHeight: 460,
                                       expansion: $logExpanded)
                    }

                    if let result = model.applyResult {
                        resultView(result)
                    }
                    failureDetailSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)

            Divider()

            // Outside the ScrollView on purpose: the command has to stay on screen while the
            // toggles above it move, or it can't be watched changing.
            commandPreview

            footer
        }
        .padding()
        // The expanded transcript needs somewhere to go: without the taller ideal, growing the log
        // only steals height from the controls above it inside a sheet that never resizes.
        .frame(minWidth: 640, minHeight: 320, idealHeight: logExpanded ? 820 : 520)
        // Verify from inside Apply: the report sheet has no "Continue to Apply..." here —
        // Apply is already the presenter, so closing the report returns straight to it.
        .sheet(isPresented: $showValidate) { ValidateSheet() }
        .confirmationDialog("Verification found problems", isPresented: $confirmUnverifiedApply,
                            titleVisibility: .visible) {
            Button("Apply anyway", role: .destructive) { startApply() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(unverifiedApplyMessage)
        }
    }

    private var header: some View {
        HStack {
            Text("Apply to the tenant").font(.headline)
            Spacer()
            Button("Clear") { model.clearApplyOutput() }
                .disabled(model.isWriting || (model.applyProgressLog.isEmpty && model.applyResult == nil
                                              && model.lastWriteError == nil && model.syncFailure == nil))
        }
    }

    // MARK: the verdict — what happened, pinned where it cannot be scrolled away

    /// Four states, one banner.
    private enum Verdict {
        case running
        case succeeded(ApplyResult)
        case partial(ApplyResult)
        case failed
    }

    /// A RESULT decides between succeeded and partial; `syncFailure` only means "failed" when
    /// there is no result at all. Both are set for a partially-applied sync — `SyncFailure.from(
    /// applyResult:)` is the item-level failure — and reading the failure first would report a
    /// sync that wrote nine of ten configurations as an outright "Sync FAILED".
    private var verdict: Verdict? {
        if model.isWriting { return .running }
        if let result = model.applyResult {
            // Either signal is enough to withhold the green verdict: the phase counters and the
            // per-item rows are two different numbers out of abctl, and the honest reading of a
            // disagreement between them is "something failed", never "all clear".
            return result.totalErrors > 0 || model.syncFailure != nil ? .partial(result) : .succeeded(result)
        }
        if model.syncFailure != nil { return .failed }
        // `lastWriteError` is SHARED with every other gated write in the app (a failed config
        // delete leaves it set), so it only counts as a sync failure once this sheet has actually
        // run something — `apply()` clears the progress log and writes its first line before any
        // of this can be true. Without that guard, opening Apply after an unrelated write failure
        // would greet the user with "Sync FAILED" for a sync that never happened.
        if !model.applyProgressLog.isEmpty, model.lastWriteError != nil { return .failed }
        return nil
    }

    /// The run is over, one way or another — which is also what makes the dismiss button "Done".
    private var hasTerminalOutcome: Bool {
        guard let verdict else { return false }
        if case .running = verdict { return false }
        return true
    }

    /// Structurally ValidateSheet's verdict view — large symbol, headline, one detail line, tinted
    /// rounded background — because this sheet and that one are read in the same breath and a
    /// second visual vocabulary for "it went wrong" is one the reader has to learn twice.
    @ViewBuilder private var verdictBanner: some View {
        if let verdict {
            HStack(alignment: .top, spacing: 10) {
                verdictSymbol(verdict)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verdictHeadline(verdict))
                        .font(.headline)
                        .foregroundStyle(verdictTint(verdict))
                        .textSelection(.enabled)
                    Text(verdictDetail(verdict))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if showsCopyError(verdict) {
                    // Only where there is something to report: the headline plus the full details,
                    // the failing rows and the log file path, in one paste.
                    CommandCopyButton(text: verdictCopyText,
                                      title: "Copy Error",
                                      showsTitle: true,
                                      help: "Copy the failure and its details to the clipboard. " + TranscriptView.sharingCaveat)
                        .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(verdictTint(verdict).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Copy Error appears where there is an error to copy — a clean apply and a run still in
    /// flight get no button rather than one that copies "everything worked".
    private func showsCopyError(_ verdict: Verdict) -> Bool {
        switch verdict {
        case .running, .succeeded: return false
        case .partial, .failed: return true
        }
    }

    @ViewBuilder private func verdictSymbol(_ verdict: Verdict) -> some View {
        switch verdict {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(Color.green)
        case .partial:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(Color.orange)
        case .failed:
            // Distinct from the partial glyph: "nothing landed" and "some of it landed" are
            // different situations to be in, and the symbol is the fastest way to tell them apart.
            Image(systemName: "xmark.octagon.fill").font(.title2).foregroundStyle(Color.red)
        }
    }

    private func verdictTint(_ verdict: Verdict) -> Color {
        switch verdict {
        case .running: return .secondary
        case .succeeded: return .green
        case .partial: return .orange
        case .failed: return .red
        }
    }

    private func verdictHeadline(_ verdict: Verdict) -> String {
        switch verdict {
        case .running: return "Applying to Apple Business…"
        case .succeeded(let result): return "Applied \(result.totalWrites) change(s)"
        case .partial(let result):
            // Never print the count blindly. A run whose every row is `done` and whose
            // counters are 0 can STILL have failed — that is precisely the incident this
            // screen exists to surface (abctl exits non-zero when the post-apply read-back
            // can't show Apple stored the write), and "Applied 3, 0 failed" is the one
            // sentence on this screen that cannot be scrolled away.
            let failed = failedCount(result)
            if failed > 0 { return "Applied \(result.totalWrites), \(failed) failed" }
            return "Applied \(result.totalWrites), but the run FAILED"
        case .failed: return "Sync FAILED"
        }
    }

    /// One line of evidence under the headline, joined the way ValidateSheet joins its verdict
    /// detail. For a failure the FIRST part is abctl's own short headline — the sentence the user
    /// previously had to go find at the bottom of a 300-line log pane.
    private func verdictDetail(_ verdict: Verdict) -> String {
        switch verdict {
        case .running:
            return model.applyProgressLog.last ?? "Writing to the tenant — leave this open until it finishes."
        case .succeeded(let result):
            var parts = ["\(result.totalWrites) write(s)"]
            if result.totalSkipped > 0 { parts.append("\(result.totalSkipped) skipped") }
            parts.append("nothing failed")
            return parts.joined(separator: " — ")
        case .partial(let result):
            // abctl's own sentence about the FIRST failure leads, for the same reason it does in
            // the abort case: "1 change failed — update-abm Wi-Fi: 403 …" is the thing to act on,
            // and it used to be somewhere in the middle of the log.
            var parts = [model.syncFailure != nil ? failureHeadline : "\(failedCount(result)) write(s) failed"]
            if result.totalSkipped > 0 { parts.append("\(result.totalSkipped) skipped") }
            // Point at the pane that actually holds the evidence. With no failed rows, every
            // row in Results is green — sending the reader there to find the failure is
            // misdirection; the reason is in abctl's narration and in the log file.
            parts.append(failedCount(result) > 0
                         ? "Results below lists every outcome"
                         : "every change reported done — the reason is in Progress below and in the log file")
            return parts.joined(separator: " — ")
        case .failed:
            var parts = [failureHeadline]
            // A terminal failure can still have written something first, and "Sync FAILED" alone
            // would read as "nothing changed" — the most expensive wrong assumption on this screen.
            if let result = model.applyResult, result.totalWrites > 0 {
                parts.append("\(result.totalWrites) write(s) completed before it stopped")
            }
            return parts.joined(separator: " — ")
        }
    }

    /// How many ITEMS failed: the larger of abctl's phase counters and the rows actually marked
    /// error. Same reasoning as `verdict` — where the two disagree, the count that hides a failure
    /// is the wrong one to print above a tenant write.
    ///
    /// It can legitimately be 0 on a failed run: a verdict-level failure (post-apply verification,
    /// a baseline that would not save) fails the sync without failing any single item. Callers
    /// must therefore branch on it rather than print it — see `verdictHeadline`.
    private func failedCount(_ result: ApplyResult) -> Int {
        max(result.totalErrors, result.rows.filter(\.failed).count)
    }

    /// abctl's short reason. `syncFailure` is the structured one; `lastWriteError` is what the older
    /// path sets (abctl missing, a decode failure) and is still the only thing there in that case.
    private var failureHeadline: String {
        model.syncFailure?.headline ?? model.lastWriteError ?? "abctl sync --apply did not complete."
    }

    /// The full failure text, as one paste: what happened, why, which rows failed, and where the
    /// log file is. Assembled at click time (CommandCopyButton takes an autoclosure).
    private var verdictCopyText: String {
        var parts: [String] = []
        if let verdict {
            parts.append(verdictHeadline(verdict))
            parts.append(verdictDetail(verdict))
        }
        // `details` already IS the failed-row list for an item-level failure, so the rows are only
        // rebuilt when there is no structured failure to quote.
        if let details = failureDetails {
            parts.append(details)
        } else if let result = model.applyResult {
            let failed = result.rows.filter(\.failed).map { "\($0.action) \($0.name) — \($0.detail)" }
            if !failed.isEmpty { parts.append(failed.joined(separator: "\n")) }
        }
        if let url = model.lastRunLogURL { parts.append("Log file: \(url.path)") }
        return parts.joined(separator: "\n\n")
    }

    /// abctl's long-form failure output, trimmed; nil when there is nothing beyond the headline.
    private var failureDetails: String? {
        guard let failure = model.syncFailure else { return nil }
        let details = failure.details.trimmingCharacters(in: .whitespacesAndNewlines)
        return details.isEmpty ? nil : details
    }

    /// The failure in full, in the scrolling body — the banner carries the one-line verdict, this
    /// carries everything abctl said about it. Falls back to `lastWriteError` exactly as before
    /// when there is no structured failure to show.
    ///
    /// Only where there is no result: when a sync half-applied, `syncFailure.details` IS the list
    /// of failed items, and the Results pane right above already shows every one of them with its
    /// status — printing the same failures twice, in two formats, on the one screen that has to be
    /// read carefully is how the original log blob got unreadable.
    @ViewBuilder private var failureDetailSection: some View {
        if model.applyResult != nil {
            EmptyView()
        } else if model.syncFailure != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text(failureHeadline)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let details = failureDetails {
                    Text(details)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = model.lastWriteError {
            Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
        }
    }

    /// The exact `sync --apply` the Apply button will shell out, rebuilt from the SAME argv
    /// builder the client runs — the flags are never re-spelled here, so the line cannot drift
    /// from the invocation. It reads as a final statement of intent above a gated tenant write,
    /// and every control in this sheet visibly rewrites it.
    ///
    /// The toggles go in RAW — exactly as `AppModel.apply` passes them. Git-as-truth forcing
    /// `--prune` on is the builder's own rule now, not a condition this view repeats: the
    /// preview once re-derived it, which meant changing the rule in `apply()` would have left
    /// this line quietly advertising a command without the most destructive flag it can apply.
    private var commandPreview: some View {
        CommandPreview(argv: model.previewArgv(
                        AbctlClient.syncApplyArgs(prune: prune,
                                                  limitWrites: limitWrites,
                                                  gitSourceOfTruth: model.gitSourceOfTruth,
                                                  refresh: model.refreshMode,
                                                  verify: model.verifyMode)),
                       cwd: model.repoRoot,
                       caption: "Apply runs exactly this — the --yes is the confirmation you give by pressing it.")
    }

    /// Parsed once, used by both the preview and the run: the circuit breaker has to mean the
    /// same thing in the line the user reads as in the process that starts. Non-numeric text
    /// is nil (unlimited), exactly as before.
    private var limitWrites: Int? { Int(limitText.trimmingCharacters(in: .whitespaces)) }

    private var footer: some View {
        HStack {
            if model.isWriting { ProgressView().controlSize(.small) }
            Spacer()
            // "Cancel" until the run reaches an outcome, "Done" after — INCLUDING a failed one.
            // Keyed off applyResult alone, a terminal failure (which leaves it nil) left the sheet
            // offering to cancel something that had already happened.
            Button(hasTerminalOutcome ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                // Verification is advisory: never verified or a clean report applies in one
                // click exactly as before. Only a FAILED report escalates to a second confirm,
                // because pushing a malformed profile to Apple Business is expensive to undo.
                if model.validationReport?.ok == false {
                    confirmUnverifiedApply = true
                } else {
                    startApply()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isWriting || (model.plan?.actionableChangeCount ?? 0) == 0)
        }
    }

    /// The write itself, factored out so the one-click path and the "Apply anyway" confirm
    /// run identical code (the button IS the gate; the dialog is just an extra turn of it).
    private func startApply() {
        Task {
            _ = await model.apply(prune: prune, limitWrites: limitWrites)
        }
    }

    /// Pre-flight verification of the LOCAL `gitops/` profiles (`abctl validate --json`) — no
    /// tenant calls, no credentials. Checking here, one step before the only screen that
    /// writes, is where a malformed profile or a dangling blueprint reference is cheapest to
    /// catch. It informs rather than blocks: see the Apply button for the one gate it adds.
    @ViewBuilder private var verificationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if model.isValidating {
                    ProgressView().controlSize(.small)
                    Text("Checking profiles…").foregroundStyle(.secondary)
                    Spacer()
                } else if let report = model.validationReport {
                    Image(systemName: report.ok ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(report.ok ? .green : .red)
                    Text(verificationSummary(report))
                    if let checked = lastValidatedText {
                        Text(checked).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review…") { showValidate = true }
                } else {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    Text("Configurations not verified").foregroundStyle(.secondary)
                    Spacer()
                    Button("Verify…") { showValidate = true }
                }
            }
            // validate's own failures (no workspace, abctl missing) never reach the report,
            // so surface them here instead of leaving the row stuck on "not verified".
            if let error = model.validationError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    /// "Checked HH:mm:ss" for the last verification — the same confirmation stamp DiffView
    /// prints for the plan, so a re-run is visible even when the verdict is unchanged.
    private var lastValidatedText: String? {
        guard let checked = model.lastValidatedAt else { return nil }
        return "Checked \(checked.formatted(date: .omitted, time: .standard))"
    }

    /// The one-line verdict for the row (built as a String, like applySummary/planSummary,
    /// rather than a ternary inside `Text`).
    private func verificationSummary(_ report: ValidationReport) -> String {
        if report.ok { return "Verified — \(report.passed) profile(s) ok" }
        // `problemCount` counts every route to ok:false — failing files, broken blueprint
        // references, and a failed external validator — so this row can never claim a
        // not-ok report has nothing wrong with it.
        return "Verification found \(report.problemCount) problem(s)"
    }

    /// The "Apply anyway" message. Deliberately phrased in PROBLEMS, not profiles: a report
    /// fails on a blueprint that references a missing configuration, or on a non-zero
    /// `$ABCTL_VALIDATOR` exit, without any single profile failing — and "N profile(s) failed
    /// validation" would then send the user hunting through a list that is entirely green.
    private var unverifiedApplyMessage: String {
        let tail = " Applying now can push a broken profile to Apple Business. Apply anyway?"
        guard let report = model.validationReport, report.problemCount > 0 else {
            // ok:false with nothing enumerable (a future abctl reason): say only what we know.
            return "Verification did not pass." + tail
        }
        var parts: [String] = []
        if report.failed > 0 { parts.append("\(report.failed) failing profile(s)") }
        if !report.treeErrors.isEmpty {
            parts.append("\(report.treeErrors.count) blueprint/tree error(s)")
        }
        if report.validatorFailed, let code = report.validatorExitCode {
            parts.append("the external validator exited \(code)")
        }
        let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        return "\(report.problemCount) problem(s) were found\(detail); Review… lists them." + tail
    }

    private func applySummary(_ plan: Plan) -> String {
        let writes = plan.actionableChangeCount
        let blocked = plan.blockedChangeCount
        if blocked == 0 {
            return "\(writes) pending change(s) can be applied to Apple Business."
        }
        if writes == 0 {
            return "\(blocked) blocked pending item(s) need their configuration created in Apple before they can attach."
        }
        return "\(writes) pending change(s) can be applied; \(blocked) dependent item(s) are blocked until their config has an Apple id."
    }

    @ViewBuilder private func resultView(_ result: ApplyResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(result.totalWrites) write(s) - \(result.totalErrors) error(s) - \(result.totalSkipped) skipped")
                    .foregroundStyle(result.totalErrors > 0 ? .red : .green)
                if !result.rows.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(result.rows) { row in
                                OutcomeResultRow(row: row)
                                Divider()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                    // Same reason as the transcript's: a hidden overlay scroller makes a pane with
                    // twenty outcomes in it look like a pane with four.
                    .scrollIndicators(.visible)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Results")
                Spacer()
                // The outcome rows are the other half of "the sync output" people paste into
                // tickets; selecting twenty wrapped rows by hand is not a copy affordance.
                CommandCopyButton(text: resultsText(result),
                                  title: "Copy Results",
                                  help: "Copy every outcome row as text. " + TranscriptView.sharingCaveat)
            }
        }
    }

    /// The results pane as plain text, in the order it is displayed.
    private func resultsText(_ result: ApplyResult) -> String {
        let header = "\(result.totalWrites) write(s) - \(result.totalErrors) error(s) - \(result.totalSkipped) skipped"
        let rows = result.rows.map { "\($0.status): \($0.action) \($0.name) - \($0.detail)" }
        return ([header] + rows).joined(separator: "\n")
    }
}

private struct OutcomeResultRow: View {
    let row: OutcomeRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
            Text(row.action)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.caption)
                    .textSelection(.enabled)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var iconName: String {
        switch row.status {
        case "error": return "xmark.circle"
        case "skipped": return "minus.circle"
        default: return "checkmark.circle"
        }
    }

    private var iconColor: Color {
        switch row.status {
        case "error": return .red
        case "skipped": return .secondary
        default: return .green
        }
    }
}
