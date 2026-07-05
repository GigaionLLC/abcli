// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Blueprints list.
struct BlueprintsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Table(model.blueprints) {
            TableColumn("Name") { Text($0.attr("name") ?? $0.id) }
            TableColumn("Status") { Text($0.attr("status") ?? "—") }
            TableColumn("ID") { Text($0.id).font(.system(.body, design: .monospaced)) }
        }
        .overlay {
            ListStateOverlay(isLoading: model.isLoading, error: model.loadError,
                             isEmpty: model.blueprints.isEmpty,
                             emptyTitle: "No blueprints", emptySymbol: "square.stack.3d.up")
        }
        .navigationTitle("Blueprints")
        .toolbar { RefreshButton { await model.loadBlueprints() } }
        .task {
            if model.blueprints.isEmpty { await model.loadBlueprints() }
        }
    }
}
