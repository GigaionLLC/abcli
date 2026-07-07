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
                    Button { showApply = true } label: { Label("Apply...", systemImage: "checkmark.circle") }
                        .disabled((model.plan?.actionableChangeCount ?? 0) == 0)
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
                                          blocked: !item.isActionable)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
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
    let action: String
    let target: String
    var secondary: String?
    let detail: String
    var blocked = false

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
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
