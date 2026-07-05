// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The GitOps hero: the 3-way plan from `abctl diff --json`. An empty plan = in sync;
/// otherwise it lists the config + blueprint-membership changes a reconcile would make.
struct DiffView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let plan = model.plan {
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
        .navigationTitle("Diff / Drift")
        .toolbar { RefreshButton { await model.loadPlan() } }
        .task {
            if model.plan == nil { await model.loadPlan() }
        }
    }

    @ViewBuilder private func planContent(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("\(plan.changeCount) pending change(s)", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
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
