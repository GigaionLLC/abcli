// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The GitOps hero: the 3-way plan from `abctl diff --json`, and the gated `sync --apply`.
/// Both resolve the `gitops/` tree relative to a chosen workspace directory.
struct DiffView: View {
    @Environment(AppModel.self) private var model
    @State private var showWorkspacePicker = false
    @State private var sheet: GitOpsSheet?
    @State private var queuedSheet: GitOpsSheet?
    /// The Git-source-of-truth value the toolbar switch staged, awaiting confirmation. It
    /// lives HERE, not in the control, because the dialog that confirms it is presented from
    /// `content` — a toolbar item is the one place on macOS where presenting is unreliable.
    @State private var pendingGitSourceOfTruth: Bool?

    /// Which modal is up — ONE piece of state instead of two independent booleans. On macOS,
    /// presenting a second sheet while the first is still dismissing silently no-ops, and
    /// swapping `.sheet(item:)`'s item inside a single update can drop the new presentation
    /// outright. So the verify → apply hand-off *queues* the next sheet and `onDismiss`
    /// presents it once the validate sheet is really gone: no timers, no lost hand-off, and
    /// never two sheets racing for the same window.
    private enum GitOpsSheet: String, Identifiable {
        case validate, apply
        var id: String { rawValue }
    }

    var body: some View {
        // The notice sits IN the layout, not in a `.safeAreaInset`. As an inset it reserved space
        // by measuring wrapping, `fixedSize` text against an as-yet-unresolved width, and while a
        // notice was up that bad measurement inset `planContent`'s ScrollView clean out of view:
        // the plan finished in ~1.4s and the pane stayed empty until the banner's 10-second
        // auto-dismiss collapsed the inset. That reads as "it hangs after the sync screen, then
        // eventually loads" — on a timer, with nothing to click. It only ever happened after a
        // source-of-truth flip because that is the only thing that posts a notice here.
        // ApplySheet has always stacked the banner this way and has never shown the fault.
        VStack(spacing: 0) {
            NoticeBanner() // a confirmed mode flip is announced, not silent
            content
        }
            .navigationTitle("Diff / Drift")
            .toolbar {
                if model.repoRoot != nil {
                    // A plain button: it shows ON/OFF and stages the flip, nothing more. The
                    // confirmation and the commit belong to `.gitSourceOfTruthConfirmation`
                    // on `content` below — see that modifier for why.
                    GitSourceOfTruthControl(layout: .toolbar,
                                            isOn: model.gitSourceOfTruth,
                                            pending: $pendingGitSourceOfTruth)
                    // These four SHOW THEIR TITLES. A macOS toolbar renders a bare `Label` as
                    // its icon alone, and with no `.help` there is not even a tooltip to fall
                    // back on — the row read as four anonymous glyphs, two of which
                    // (checkmark.shield / checkmark.circle) are near-identical at toolbar size
                    // while doing very different things: one only reads local files, the other
                    // writes the live tenant. The word is the affordance, exactly as it is on
                    // the Git-source-of-truth control sitting beside them.
                    Button { sheet = .validate } label: { Label("Verify Configs", systemImage: "checkmark.shield") }
                        .toolbarLabel("Check the profiles in gitops/lib against Apple's schema. Reads local files only — no tenant change.")
                        .disabled(model.isSeeding)
                    Button { sheet = .apply } label: { Label("Apply…", systemImage: "checkmark.circle") }
                        .toolbarLabel("Reconcile Apple Business with this plan. Opens a sheet that previews the exact abctl command and asks you to confirm before anything is written.")
                        .disabled((model.plan?.actionableChangeCount ?? 0) == 0)
                    Button { model.refreshPlan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .toolbarLabel("Recompute the plan: re-read gitops/ and re-fetch the live tenant.")
                        .disabled(model.isLoading || model.isSeeding)
                }
                Button { showWorkspacePicker = true } label: { Label("Workspace", systemImage: "folder") }
                    .toolbarLabel("Choose the folder that contains your gitops/ tree. Every command on this screen runs there.")
            }
            .fileImporter(isPresented: $showWorkspacePicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.setWorkspace(url) }
            }
            .sheet(item: $sheet, onDismiss: presentQueuedSheet) { which in
                switch which {
                case .validate:
                    ValidateSheet(onContinue: {
                        // Queue Apply, then make sure this sheet is on its way out — ValidateSheet
                        // dismisses itself, and a second nil write is a harmless no-op. Either
                        // order lands in `onDismiss`, which is what actually presents Apply.
                        queuedSheet = .apply
                        sheet = nil
                    })
                case .apply:
                    ApplySheet()
                }
            }
            // The toolbar switch's consent gate, presented from the content view like every
            // other presentation on this screen. The callback keeps the old behavior of
            // recomputing the plan after a real (confirmed) change.
            .gitSourceOfTruthConfirmation(pending: $pendingGitSourceOfTruth) { _ in
                model.refreshPlan()
            }
            .task(id: model.repoRoot) {
                if model.repoRoot != nil && model.plan == nil { model.refreshPlan() }
            }
    }

    /// Present whatever a closing sheet asked for next, now that it is fully dismissed.
    private func presentQueuedSheet() {
        guard let next = queuedSheet else { return }
        queuedSheet = nil
        sheet = next
    }

    @ViewBuilder private var content: some View {
        if model.repoRoot == nil {
            ContentUnavailableView {
                Label("No GitOps workspace", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose the directory that contains your gitops/ tree to compute drift and apply.")
            } actions: {
                Button("Choose Workspace...") { showWorkspacePicker = true }
            }
        } else if model.isSeeding {
            workingView("Initializing workspace from the tenant...")
        } else if model.isLoading {
            // Check isLoading BEFORE the plan branch, so a refresh from an already-computed
            // state visibly shows progress instead of silently redisplaying the old result.
            workingView("Computing plan...")
        } else if model.needsSeed {
            seedPrompt
        } else if let plan = model.plan {
            if plan.isEmpty {
                ContentUnavailableView("In sync", systemImage: "checkmark.seal",
                                       description: inSyncDescription)
            } else {
                planContent(plan)
            }
        } else if let error = model.loadError {
            ContentUnavailableView("Couldn't compute the plan", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            ContentUnavailableView("No plan yet", systemImage: "arrow.triangle.branch",
                                   description: Text("Refresh to compute drift."))
        }
    }

    /// "Checked HH:mm:ss" from the last successful plan compute: positive confirmation that a
    /// refresh actually ran, even when the result is unchanged (still in sync).
    private var lastCheckedText: String? {
        guard let checked = model.lastCheckedAt else { return nil }
        return "Checked \(checked.formatted(date: .omitted, time: .standard))"
    }

    private var inSyncDescription: Text {
        let base = Text("Git and the tenant agree: no drift.")
        guard let checked = lastCheckedText else { return base }
        return base + Text("\n\(checked)").font(.caption)
    }

    @ViewBuilder private func workingView(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView(title)
                .controlSize(.large)
            // Turning git source of truth ON makes the FIRST plan after the flip materially
            // slower, and silence there reads as a hung window: every live config absent from
            // git now needs its profile fetched from Apple, because that mode may delete or
            // detach it and abctl archives before it does (internal/cli/phase1.go,
            // fetchLiveConfigsSmart). Saying so is the difference between "it's working" and
            // "it's broken".
            if model.gitSourceOfTruth {
                Text("Git source of truth is ON, so Apple-only configurations are being fetched in full — the first plan after the switch is the slow one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            if !model.progressLog.isEmpty {
                // The same transcript component the Apply sheet uses: one selectable string,
                // a Copy button, a visible scroller and a way to grow it. The per-line Text
                // stack that used to live here could not be selected across lines at all — and
                // this is the pane the user watches while a slow diff or seed runs.
                TranscriptView(title: "Progress",
                               lines: model.progressLog,
                               logURL: model.lastRunLogURL)
                    .frame(maxWidth: 460)
            }
            Button("Cancel") { model.cancelWork() }
                .buttonStyle(.bordered)
        }
        .padding()
        // Claim the whole pane. Without an explicit frame this stack sizes to its content and
        // the detail column is free to lay it out somewhere the eye doesn't go — the state was
        // reported as "blank with no obvious loading indication".
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var seedPrompt: some View {
        ContentUnavailableView {
            Label("No GitOps tree here yet", systemImage: "folder.badge.plus")
        } description: {
            Text("\"\(model.repoRoot?.lastPathComponent ?? "This folder")\" has no gitops/ directory. "
                 + "Initialize it from the current tenant; abctl downloads live configurations and "
                 + "blueprints into gitops/ (plus a baseline) so you can diff and apply.")
        } actions: {
            Button("Initialize from Tenant...") { model.startSeed() }
                .buttonStyle(.borderedProminent)
            Button("Choose a Different Folder...") { showWorkspacePicker = true }
                .buttonStyle(.link)
            if let error = model.loadError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func planContent(_ plan: Plan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Label(planSummary(plan),
                          systemImage: plan.actionableChangeCount > 0 ? "exclamationmark.circle" : "info.circle")
                        .foregroundStyle(plan.actionableChangeCount > 0 ? .orange : .secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let root = model.repoRoot {
                            Text(root.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                        if let checked = lastCheckedText {
                            Text(checked).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding([.horizontal, .top])

                // A refused adopt has to say so HERE. It is the only write this screen can
                // start, and `runWrite` reports failure by setting lastWriteError — with
                // nothing rendering it, a row-button click that abctl rejected (unmanaged
                // collection, no manifest for the blueprint, member not actually attached)
                // looked like a click that did nothing at all.
                if let error = model.lastWriteError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding([.horizontal, .top])
                }

                if !plan.configs.isEmpty {
                    Text("Configurations").font(.headline).padding([.horizontal, .top])
                    VStack(spacing: 0) {
                        ForEach(plan.configs) { item in
                            PlanDetailRow(action: item.action, target: item.name, detail: item.detail)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }

                if !plan.blueprints.isEmpty {
                    Text("Blueprint membership").font(.headline).padding([.horizontal, .top])
                    VStack(spacing: 0) {
                        ForEach(plan.blueprints) { item in
                            PlanDetailRow(action: item.action,
                                          target: item.blueprint,
                                          secondary: item.config,
                                          detail: item.detail,
                                          blocked: !item.isActionable,
                                          adopt: adoptAction(for: item))
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        // macOS hides the overlay scroller until you scroll, which makes a long plan look like it
        // ends at the fold — the same defect the sync sheet was reported for.
        .scrollIndicators(.visible)
    }

    /// The per-row escape hatch for "this member belongs in git — stop proposing to remove it".
    ///
    /// Offered on the two rows where a member is live in Apple Business but missing from the
    /// manifest: `detach-*` (git source of truth ON — the plan wants it gone) and `adopt-*`
    /// (OFF — the plan already wants to record it, and this does it now without a full Apply).
    /// Everything else returns nil: an attach row's member is already declared in git, and a
    /// blueprint-level row names no member to adopt.
    private func adoptAction(for item: BlueprintChange) -> PlanDetailRow.AdoptAction? {
        guard item.isDetach || item.isAdopt, item.memberKind != nil,
              let name = item.config, !name.isEmpty else { return nil }
        return PlanDetailRow.AdoptAction(
            title: item.isDetach ? "Keep in Git" : "Record in Git",
            help: item.isDetach
                ? "Add \(name) to \(item.blueprint)'s manifest in gitops/blueprints/, so this stops being proposed for detach. Writes a local file — Apple Business is not touched."
                : "Write \(name) into \(item.blueprint)'s manifest now, without waiting for a full Apply. Local file only.",
            change: item)
    }

    private func planSummary(_ plan: Plan) -> String {
        if plan.blockedChangeCount == 0 {
            return "\(plan.actionableChangeCount) pending change(s)"
        }
        if plan.actionableChangeCount == 0 {
            return "\(plan.blockedChangeCount) blocked pending item(s)"
        }
        return "\(plan.actionableChangeCount) pending change(s), \(plan.blockedChangeCount) blocked pending item(s)"
    }
}

private struct PlanDetailRow: View {
    /// An optional trailing button on the row. Rows are otherwise pure display, so WHETHER a row
    /// offers this is the host's decision (see DiffView.adoptAction) — the row only renders it.
    struct AdoptAction {
        let title: String
        let help: String
        let change: BlueprintChange
    }

    let action: String
    let target: String
    var secondary: String?
    let detail: String
    var blocked = false
    var adopt: AdoptAction?

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(action)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(blocked ? Color.red.opacity(0.12) : Color.orange.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 4))
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 3) {
                Text(target)
                    .font(.body)
                    .textSelection(.enabled)
                if let secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if let adopt {
                Button(adopt.title) { Task { _ = await model.adoptMember(adopt.change) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(adopt.help)
                    .disabled(model.isWriting || model.isLoading)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
