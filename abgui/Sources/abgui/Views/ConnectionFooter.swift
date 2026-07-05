// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The sidebar footer: a connection dot + summary, and a context field / reconnect.
struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                TextField("context", text: $model.context)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { Task { await model.check() } }
                Button {
                    Task { await model.check() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reconnect")
            }
        }
        .padding(8)
    }

    private var dotColor: Color {
        switch model.connection {
        case .connected: return .green
        case .checking, .unknown: return .yellow
        case .failed: return .red
        }
    }

    private var summary: String {
        switch model.connection {
        case .unknown: return "not checked"
        case .checking: return "checking…"
        case .connected(let version, let identity):
            if let identity { return "abctl \(version.version) · \(identity.clientID)" }
            return "abctl \(version.version) · no tenant"
        case .failed(let message): return message
        }
    }
}
