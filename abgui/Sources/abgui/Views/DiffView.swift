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
                    RefreshButton { await model.loadPlan() }
                }
                Button { showWorkspacePicker = true } label: { Label("Workspace", systemImage: "folder") }
            }
            .fileImporter(isPresented: $showWorkspacePicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.setWorkspace(url) }
            }
            .sheet(isPresented: $showApply) { ApplySheet() }
            .task(id: model.repoRoot) {
                if model.repoRoot != nil && model.plan == nil { await model.loadPlan() }
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
        } else if let plan = model.plan {
            if plan.isEmpty {
                ContentUnavailableView("In sync", systemImage: "checkmark.seal",
                                       description: Text("Git and the tenant agree — no drift."))
            } else {
                planContent(plan)
            }
        } else if model.isLoading {
            ProgressView("Computing plan…")
        } else if let error = model.loadError {
            ContentUnavailableView("Couldn't compute the plan", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            ContentUnavailableView("No plan yet", systemImage: "arrow.triangle.branch",
                                   description: Text("Refresh to compute drift."))
        }
    }

    @ViewBuilder private func planContent(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("\(plan.changeCount) pending change(s)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Spacer()
                if let root = model.repoRoot {
                    Text(root.lastPathComponent).font(.caption).foregroundStyle(.secondary)
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
