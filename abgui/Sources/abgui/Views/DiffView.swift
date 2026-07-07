// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The GitOps hero: the 3-way plan from `abctl diff --json`, and the gated `sync --apply`.
/// Both resolve the `gitops/` tree relative to a chosen workspace directory.
struct DiffView: View {
    @Environment(AppModel.self) private var model
    @State private var showWorkspacePicker = false
    @State private var showApply = false

    var body: some View {
        content
            .navigationTitle("Diff / Drift")
            .toolbar {
                if model.repoRoot != nil {
                    Button { showApply = true } label: { Label("Apply…", systemImage: "checkmark.circle") }
                        .disabled(model.plan?.isEmpty ?? true)
                    Button { model.refreshPlan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.isLoading || model.isSeeding)
                }
                Button { showWorkspacePicker = true } label: { Label("Workspace", systemImage: "folder") }
            }
            .fileImporter(isPresented: $showWorkspacePicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.setWorkspace(url) }
            }
            .sheet(isPresented: $showApply) { ApplySheet() }
            .task(id: model.repoRoot) {
                if model.repoRoot != nil && model.plan == nil { model.refreshPlan() }
            }
    }

    @ViewBuilder private var content: some View {
        if model.repoRoot == nil {
            ContentUnavailableView {
                Label("No GitOps workspace", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose the directory that contains your gitops/ tree to compute drift and apply.")
            } actions: {
                Button("Choose Workspace…") { showWorkspacePicker = true }
            }
        } else if model.isSeeding {
            workingView("Initializing workspace from the tenant…")
        } else if model.isLoading {
            // Check isLoading BEFORE the plan branch, so a refresh from an already-computed
            // state visibly shows progress instead of silently redisplaying the old result.
            workingView("Computing plan…")
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

    /// "Checked HH:mm:ss" from the last successful plan compute — positive confirmation that a
    /// refresh actually ran, even when the result is unchanged (still in sync).
    private var lastCheckedText: String? {
        guard let checked = model.lastCheckedAt else { return nil }
        return "Checked \(checked.formatted(date: .omitted, time: .standard))"
    }

    /// The "In sync" description, with the last-checked time appended when known.
    private var inSyncDescription: Text {
        let base = Text("Git and the tenant agree — no drift.")
        guard let checked = lastCheckedText else { return base }
        return base + Text("\n\(checked)").font(.caption)
    }

    /// A working state with abctl's live progress narration + a Cancel button, so a long diff/
    /// seed shows what it's doing (authenticating, fetching…) and can be stopped.
    @ViewBuilder private func workingView(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView(title)
            if !model.progressLog.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.progressLog.indices, id: \.self) { idx in
                                Text(model.progressLog[idx])
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxWidth: 460, maxHeight: 160)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.progressLog.count) { _, count in
                        if count > 0 { withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) } }
                    }
                }
            }
            Button("Cancel") { model.cancelWork() }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    /// Shown when the chosen folder has no gitops/ tree yet: offer to initialize it from the
    /// tenant (`abctl seed`) rather than dead-ending. Seeding creates gitops/ inside the folder.
    @ViewBuilder private var seedPrompt: some View {
        ContentUnavailableView {
            Label("No GitOps tree here yet", systemImage: "folder.badge.plus")
        } description: {
            Text("\"\(model.repoRoot?.lastPathComponent ?? "This folder")\" has no gitops/ directory. "
                 + "Initialize it from the current tenant — abctl downloads live configurations and "
                 + "blueprints into gitops/ (plus a baseline) so you can diff and apply.")
        } actions: {
            Button("Initialize from Tenant…") { model.startSeed() }
                .buttonStyle(.borderedProminent)
            Button("Choose a Different Folder…") { showWorkspacePicker = true }
                .buttonStyle(.link)
            if let error = model.loadError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func planContent(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Label("\(plan.changeCount) pending change(s)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
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

            if !plan.configs.isEmpty {
                Text("Configurations").font(.headline).padding([.horizontal, .top])
                Table(plan.configs) {
                    TableColumn("Action") { Text($0.action).font(.system(.body, design: .monospaced)) }
                    TableColumn("Name") { Text($0.name) }
                    TableColumn("Detail") { Text($0.detail) }
                }
            }
            if !plan.blueprints.isEmpty {
                Text("Blueprint membership").font(.headline).padding([.horizontal, .top])
                Table(plan.blueprints) {
                    TableColumn("Action") { Text($0.action).font(.system(.body, design: .monospaced)) }
                    TableColumn("Blueprint") { Text($0.blueprint) }
                    TableColumn("Config") { Text($0.config ?? "—") }
                    TableColumn("Detail") { Text($0.detail) }
                }
            }
        }
    }
}
