// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Org devices list (read-only; the API has no query engine, so filtering is client-side).
struct DevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Table(model.devices) {
            TableColumn("Serial") { Text($0.attr("serialNumber") ?? $0.id) }
            TableColumn("Family") { Text($0.attr("productFamily") ?? "—") }
            TableColumn("Model") { Text($0.attr("deviceModel") ?? "—") }
        }
        .overlay {
            ListStateOverlay(isLoading: model.isLoading, error: model.loadError,
                             isEmpty: model.devices.isEmpty,
                             emptyTitle: "No devices", emptySymbol: "laptopcomputer")
        }
        .navigationTitle("Devices")
        .toolbar { RefreshButton { await model.loadDevices() } }
        .task {
            if model.devices.isEmpty { await model.loadDevices() }
        }
    }
}
