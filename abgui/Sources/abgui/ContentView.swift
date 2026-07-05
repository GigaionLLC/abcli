// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// v0 window: prove the embedded abctl runs and, if a tenant is configured, show its
/// identity. The browse screens (Configurations / Blueprints / Devices / diff / drift)
/// arrive in v1 — see ../../docs/abgui-design.md §4 and §9.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("abgui").font(.largeTitle).bold()
                Text("A native front-end to the embedded abctl.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("context (optional, e.g. prod)", text: $model.context)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button("Test connection") { Task { await model.check() } }
                    .keyboardShortcut(.defaultAction)
            }

            statusView

            Spacer()
        }
        .padding(24)
        .task { await model.check() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView("Checking…")
        case .connected(let version, let identity):
            GroupBox("Connected") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("abctl", value: version.version)
                    if let identity {
                        LabeledContent("client", value: identity.clientID)
                        LabeledContent("inventory",
                                       value: "\(identity.configurations) configurations · \(identity.blueprints) blueprints")
                    } else {
                        Text("Binary OK, but no tenant is configured — set a context or an abctl .env.")
                            .foregroundStyle(.secondary)
                    }
                    Text("capabilities: \(version.capabilities.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            GroupBox("Not connected") {
                Text(message)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
