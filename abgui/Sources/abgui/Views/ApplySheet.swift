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

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            NoticeBanner() // flipping the source-of-truth mode from inside this sheet says so
            header

            Divider()

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
                        logView(title: "Progress", lines: model.applyProgressLog)
                    }

                    if let result = model.applyResult {
                        resultView(result)
                    }
                    if let error = model.lastWriteError {
                        Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                    }
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
        .frame(minWidth: 640, minHeight: 320, idealHeight: 520)
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
                .disabled(model.isWriting || (model.applyProgressLog.isEmpty && model.applyResult == nil && model.lastWriteError == nil))
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
            Button(model.applyResult == nil ? "Cancel" : "Done") { dismiss() }
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

    @ViewBuilder private func logView(title: String, lines: [String]) -> some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if lines.isEmpty {
                            Text("Starting...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(lines.indices, id: \.self) { idx in
                            Text(lines[idx])
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(minHeight: 110, maxHeight: 150)
                .onChange(of: lines.count) { _, count in
                    if count > 0 { withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) } }
                }
            }
        } label: {
            Text(title)
        }
    }

    @ViewBuilder private func resultView(_ result: ApplyResult) -> some View {
        GroupBox("Results") {
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
