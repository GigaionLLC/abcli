// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The sidebar footer: a connection dot + summary, a Settings affordance (with a call-to-
/// action when there's no tenant yet), and a context field / reconnect.
struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Connection settings")
            }
            if needsSetup {
                Button { openSettings() } label: {
                    Label("Set up connection…", systemImage: "key.horizontal")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .help("Enter your Apple Business API Client ID + private key")
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

    /// True when abctl runs but no tenant is authenticated — the state that needs Settings.
    private var needsSetup: Bool {
        switch model.connection {
        case .failed: return true
        case .connected(_, let identity): return identity == nil
        default: return false
        }
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
