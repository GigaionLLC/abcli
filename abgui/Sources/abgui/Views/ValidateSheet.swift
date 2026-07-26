// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Pre-sync verification: `abctl validate --json` over the chosen workspace.
///
/// Local-only and credential-free — it parses `gitops/lib/*.mobileconfig` and checks that
/// the blueprint manifests only reference configurations that actually exist, so it can be
/// run before (and without) any tenant call. Verification INFORMS, it does not gate: a
/// failed report never disables Continue/Apply, it just makes the problems visible first
/// (ApplySheet adds the "apply anyway?" confirm).
struct ValidateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Supplied by the caller (DiffView / ApplySheet) so a verified tree can go straight to
    /// Apply. nil = the sheet was opened just to look.
    var onContinue: (() -> Void)? = nil

    /// The external-validator disclosure, once the user has opened or closed it themselves.
    /// nil = untouched, in which case it follows the report: OPEN when the validator is why
    /// the report failed, because its exit code and output are then the only evidence there
    /// is, and burying that behind a click leaves the verdict unexplained.
    @State private var validatorExpanded: Bool?

    /// Owned HERE, exactly as ApplySheet owns its own: this sheet does not resize either, so a
    /// transcript that grows inside it would only squeeze the report above it and re-create the
    /// scroll-inside-a-scroll the expand button exists to remove. Growing the pane grows the
    /// sheet (see the frame below).
    @State private var logExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)

            Divider()

            commandPreview

            footer
        }
        .padding()
        // The taller ideal is what gives an expanded validator transcript somewhere to go —
        // same rule as ApplySheet, since both are fixed-height sheets hosting the same pane.
        .frame(minWidth: 640, minHeight: 360, idealHeight: logExpanded ? 820 : 560)
        .task {
            // First open only. Re-opening the sheet must not re-run a (possibly slow)
            // external validator — Re-run is the explicit refresh.
            if model.repoRoot != nil, model.validationReport == nil, !model.isValidating {
                _ = await model.validateProfiles()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Verify configurations").font(.headline)
                Text(model.repoRoot?.lastPathComponent ?? "No workspace chosen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isValidating { ProgressView().controlSize(.small) }
            Button("Re-run") { Task { _ = await model.validateProfiles() } }
                .disabled(model.isValidating || model.repoRoot == nil)
                .help("Re-read gitops/lib/ and the blueprint manifests. No credentials, no tenant calls.")
        }
    }

    @ViewBuilder private var content: some View {
        if model.repoRoot == nil {
            ContentUnavailableView {
                Label("No GitOps workspace", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose the folder that contains your gitops/ tree in Diff / Drift. "
                     + "Verification reads gitops/lib/*.mobileconfig and the blueprint manifests — "
                     + "no credentials and no tenant calls.")
            }
        } else if model.isValidating {
            ProgressView("Checking profiles…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else if let error = model.validationError {
            ContentUnavailableView("Couldn't verify the configurations", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let report = model.validationReport {
            reportContent(report)
        } else {
            ContentUnavailableView {
                Label("Not verified yet", systemImage: "checkmark.shield")
            } description: {
                Text("Parse every profile in gitops/lib/ and confirm the blueprints only reference "
                     + "configurations that exist, before anything is pushed to Apple Business.")
            } actions: {
                Button("Verify Now") { Task { _ = await model.validateProfiles() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: the report

    @ViewBuilder private func reportContent(_ report: ValidationReport) -> some View {
        verdict(report)
        if !report.treeIssues.isEmpty { treeSection(report) }
        if !report.profiles.isEmpty { profileSection(report) }
        if report.usesExternalValidator { validatorSection(report) }
        if !report.libDir.isEmpty {
            // Always say WHAT was checked: a report with no rows to show — clean, or failed
            // only on the external validator — is otherwise indistinguishable from having
            // pointed at the wrong folder.
            Label(report.libDir, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func verdict(_ report: ValidationReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(report.ok ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdictText(report)).font(.headline).textSelection(.enabled)
                Text(verdictDetail(report)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((report.ok ? Color.green : Color.red).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    /// The headline verdict. `ok` can be false with every profile parsing fine — a blueprint
    /// referencing a missing config, or a failed external validator — and each of those gets
    /// its own sentence. Naming the wrong culprit ("the tree has problems" when the tree is
    /// fine) sends the user looking for something that isn't there.
    private func verdictText(_ report: ValidationReport) -> String {
        if report.ok { return "All \(report.checked) profile(s) passed" }
        if report.validatorFailed, report.failed == 0, report.treeErrors.isEmpty {
            return "\(report.checked) profile(s) passed the built-in checks, but the external validator failed"
        }
        if report.failed == 0 { return "\(report.checked) profile(s) parsed, but the tree has problems" }
        return "\(report.failed) of \(report.checked) profile(s) have problems"
    }

    private func verdictDetail(_ report: ValidationReport) -> String {
        var parts = ["\(report.warnings) warning(s)"]
        let treeErrors = report.treeErrors.count
        if treeErrors > 0 { parts.append("\(treeErrors) blueprint/tree error(s)") }
        // The only numeric evidence when $ABCTL_VALIDATOR is what failed the report.
        if report.validatorFailed, let code = report.validatorExitCode {
            parts.append("validator exit \(code)")
        }
        if let checked = model.lastValidatedAt {
            parts.append("Checked \(checked.formatted(date: .omitted, time: .standard))")
        }
        return parts.joined(separator: " — ")
    }

    @ViewBuilder private func treeSection(_ report: ValidationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Blueprint / tree issues").font(.headline)
            ForEach(sortedTreeIssues(report)) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: issue.isError ? "xmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(issue.isError ? Color.red : Color.orange)
                        .frame(width: 16)
                        // The glyph is the only thing separating an error from a warning here.
                        .accessibilityLabel(Text(issue.isError ? "Error" : "Warning"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.message)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text(issueContext(issue))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "blueprints · missing-config · Standard Mac" — where it came from, in abctl's words.
    private func issueContext(_ issue: TreeIssue) -> String {
        var parts = [issue.scope, issue.code]
        if let target = issue.target, !target.isEmpty { parts.append(target) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func profileSection(_ report: ValidationReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Text("\(report.checked) checked — \(report.passed) ok, \(report.failed) failed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            ForEach(sortedProfiles(report)) { profile in
                ProfileReportRow(profile: profile)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func validatorSection(_ report: ValidationReport) -> some View {
        let expanded = Binding(get: { validatorExpanded ?? report.validatorFailed },
                               set: { validatorExpanded = $0 })
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("$ABCTL_VALIDATOR ran in addition to the built-in structural checks; a non-zero exit fails this report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command = report.validatorCommand, !command.isEmpty {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let code = report.validatorExitCode {
                    Text("Exit code \(code)")
                        .font(.caption)
                        .foregroundStyle(code == 0 ? Color.secondary : Color.red)
                }
                if let output = report.validatorOutput, !output.isEmpty {
                    // The same transcript pane the sync path uses. When $ABCTL_VALIDATOR is why the
                    // report failed this output is the ONLY evidence there is, so it needs the copy
                    // button and the expand toggle at least as much as the progress logs do.
                    // `follow: false` — this output is finished when it appears, and opening it
                    // scrolled to the last line would hide the first failure, not show the newest.
                    // `expansion:` is the sheet's own state: without it the pane would grow to
                    // 520pt inside a ~400pt viewport and put the nested scroll straight back.
                    TranscriptView(title: "Validator output",
                                   text: output,
                                   collapsedHeight: 160,
                                   expandedHeight: 460,
                                   follow: false,
                                   expansion: $logExpanded)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label("External validator", systemImage: "terminal")
        }
    }

    // MARK: ordering — problems first, the CLI's own order within a tier

    /// Errors before warnings. Swift's sort isn't stable, so the original index is the
    /// tiebreak: within a level abctl's order is meaningful and must survive.
    private func sortedTreeIssues(_ report: ValidationReport) -> [TreeIssue] {
        report.treeIssues.enumerated().sorted { lhs, rhs in
            if lhs.element.isError != rhs.element.isError { return lhs.element.isError }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// Failing profiles first, then merely-warning ones, then the clean majority — a long
    /// lib/ shouldn't make the user scroll to find what's broken.
    private func sortedProfiles(_ report: ValidationReport) -> [ProfileReport] {
        report.profiles.enumerated().sorted { lhs, rhs in
            let left = tier(lhs.element)
            let right = tier(rhs.element)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    private func tier(_ profile: ProfileReport) -> Int {
        if !profile.ok { return 0 }
        return profile.warnings.isEmpty ? 2 : 1
    }

    // MARK: footer

    /// What Verify / Re-run actually shells out, from the client's own argv builder. The cwd
    /// is load-bearing here rather than decoration: `validate` resolves `gitops/lib/` relative
    /// to it, so the copied form has to carry the `cd` to check the same tree this sheet did.
    /// Shown even with no workspace chosen — it is reference material, and the reader then
    /// supplies the directory themselves, which is precisely how they'd run it in a terminal.
    private var commandPreview: some View {
        CommandPreview(argv: model.previewArgv(AbctlClient.validateArgs()),
                       cwd: model.repoRoot,
                       caption: "Reads local files only — no credentials and no tenant calls.")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if onContinue != nil, model.validationReport?.ok == false {
                Text("Verification failed — applying is still allowed, but review the problems first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if onContinue != nil {
                if model.validationReport?.ok == true {
                    continueButton.buttonStyle(.borderedProminent)
                } else {
                    continueButton.buttonStyle(.bordered)
                }
            }
        }
    }

    /// Never disabled — verification informs, it does not block. macOS won't present a
    /// second sheet while this one is on screen, so dismiss FIRST and hand back after.
    private var continueButton: some View {
        Button("Continue to Apply…") {
            dismiss()
            onContinue?()
        }
    }
}

/// One lib/ profile: status, what it declares, and every problem beneath it. Shares
/// ApplySheet's OutcomeResultRow icon vocabulary so a result row reads the same
/// everywhere in the app.
private struct ProfileReportRow: View {
    let profile: ProfileReport

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
                // Symbol + tint are the whole verdict for a row with no messages under it,
                // so it has to be spoken (and readable without colour).
                .accessibilityLabel(Text(accessibilityStatus))
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.body)
                    .textSelection(.enabled)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(profile.errors) { issue in
                    IssueLine(issue: issue, isError: true)
                }
                ForEach(profile.warnings) { issue in
                    IssueLine(issue: issue, isError: false)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Identifier, size and the inner payload types — enough to recognize the profile
    /// without opening it (and the size matters: Apple Business caps a profile at 1 MiB).
    private var subtitle: String {
        var parts: [String] = []
        if let identifier = profile.identifier, !identifier.isEmpty { parts.append(identifier) }
        if let display = profile.displayName, !display.isEmpty, display != profile.name {
            parts.append(display)
        }
        parts.append(sizeText(profile.bytes))
        if !profile.payloadTypes.isEmpty { parts.append(profile.payloadTypes.joined(separator: ", ")) }
        return parts.joined(separator: " — ")
    }

    private var iconName: String {
        if !profile.ok { return "xmark.circle" }
        return profile.warnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var iconColor: Color {
        if !profile.ok { return .red }
        return profile.warnings.isEmpty ? .green : .orange
    }

    private var accessibilityStatus: String {
        if !profile.ok { return "Failed" }
        return profile.warnings.isEmpty ? "Passed" : "Passed with warnings"
    }
}

/// One error/warning under a profile: abctl's code as a chip (it's what you grep for and
/// what the docs list), then the one-sentence message.
private struct IssueLine: View {
    let issue: ValidationIssue
    let isError: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(issue.code)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background((isError ? Color.red : Color.orange).opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 3))
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(isError ? Color.red : Color.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }
}

/// Byte counts the way the 1 MiB Apple Business cap is reasoned about (KB, then MB).
private func sizeText(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kb = Double(bytes) / 1024
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    return String(format: "%.2f MB", kb / 1024)
}
