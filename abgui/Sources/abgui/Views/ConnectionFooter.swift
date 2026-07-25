// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The sidebar footer: a connection dot + summary, the abctl command last run, a Settings
/// affordance (with a call-to-action when there's no tenant yet), and a context field /
/// reconnect.
struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// Moves the sidebar selection to the Command Log (RootView owns it), so the last-command
    /// line is a way in to the full transcript rather than a dead end.
    let showCommandLog: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            // The status line and the command abctl last ran answer the same question — "what
            // is the backend doing?" — so they're one tight block rather than two footer rows.
            VStack(alignment: .leading, spacing: 2) {
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
                lastCommandRow
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

    /// The last-command line, with its height RESERVED from launch.
    ///
    /// The spec's constraint on this placement is that it must not grow the footer or push the
    /// connection dot around. Rendering the line only once a command exists satisfies that at any
    /// single instant but not over time: the footer would gain a row — and the sidebar's bottom
    /// inset would shift, mid-session — the first time any abctl command ran, on an event the
    /// user did not initiate. A hidden placeholder of exactly the same line keeps the footer one
    /// fixed height for the whole session instead. (In practice the empty state is momentary:
    /// `RootView` runs `check()` at launch, which records `abctl version` straight away.)
    @ViewBuilder private var lastCommandRow: some View {
        if let last = model.lastCommand {
            lastCommandLine(last)
        } else {
            Text(verbatim: "abctl")
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .hidden()                       // draws nothing, still claims the row's height
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    /// The abctl invocation abgui made most recently, on one truncated monospaced line: the
    /// standing reminder that every button here is really a CLI call, and the shortest route
    /// to the log that lists them all. Indented to the summary's text column so it hangs off
    /// the status line, and deliberately NOT selectable — the whole line is the button, and
    /// the Command Log is where a command gets read and copied.
    private func lastCommandLine(_ record: CommandRecord) -> some View {
        Button(action: showCommandLog) {
            Text(record.commandLine)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(record.isFailure ? Color.red : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 14) // the 8pt dot + the row's 6pt spacing
        .help("\(record.commandLine) — open the Command Log")
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
