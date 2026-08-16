// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The gated device-assignment sheet: assign or unassign the selected org devices
/// to/from an MDM server. Mirrors ApplySheet's gate — the Assign/Unassign button IS
/// the human confirm (abctl then runs with --yes). Apple processes assignment
/// ASYNCHRONOUSLY: success here means the request was ACCEPTED as an activity, whose
/// id the Check status button polls (`status activity`).
struct AssignSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The selected devices' serial numbers (org-device ids also resolve on the CLI side).
    let serials: [String]

    @State private var unassign = false
    @State private var serverID = ""
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var outcome: ActivityOutcome?
    @State private var activity: Resource?  // the last polled activity status
    @State private var statusBusy = false
    @State private var statusError: String?
    // The server-list fetch has its OWN busy/error state (like assign/poll above): this is a
    // sheet, not a pane, so it has no entry in the model's per-pane load state — and a
    // swallowed failure here would masquerade as "No MDM servers found." on a write-gating
    // picker.
    @State private var serversBusy = false
    @State private var serversError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    form
                    if let outcome { resultView(outcome) }
                    if let errorText {
                        Text(errorText).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)

            Divider()

            commandPreview

            footer
        }
        .padding()
        .frame(minWidth: 540, minHeight: 320, idealHeight: 440)
        .task {
            // The server picker feeds off the mdmServers cache; fill it on first use.
            if model.mdmServers.isEmpty {
                serversBusy = true
                do { try await model.refreshMDMServers() }
                catch { serversError = error.localizedDescription }
                serversBusy = false
            }
            if serverID.isEmpty { serverID = model.mdmServers.first?.id ?? "" }
        }
    }

    private var header: some View {
        HStack {
            Text("Device assignment").font(.headline)
            Spacer()
            Text("\(serials.count) device(s) selected").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var form: some View {
        Picker("Action", selection: $unassign) {
            Text("Assign").tag(false)
            Text("Unassign").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 240)

        Picker("MDM server", selection: $serverID) {
            ForEach(model.mdmServers) { server in
                Text(server.attr("serverName") ?? server.id).tag(server.id)
            }
        }
        .frame(maxWidth: 360)
        if model.mdmServers.isEmpty {
            if let serversError {
                Text("Couldn't load MDM servers: \(serversError)")
                    .foregroundStyle(.red).font(.caption).textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    if serversBusy { ProgressView().controlSize(.small) }
                    Text(serversBusy ? "Loading MDM servers…" : "No MDM servers found.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Devices").font(.subheadline.weight(.semibold))
            Text(serials.joined(separator: ", "))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }

        Text("Apple processes device assignment asynchronously — a success below means the request was accepted as an activity, not that it has finished. Poll it with Check status.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func resultView(_ outcome: ActivityOutcome) -> some View {
        GroupBox("Result") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(outcome.action) activity \(outcome.activityID) accepted — \(outcome.devices) device(s), server \(outcome.server)")
                    .font(.callout)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Check status") {
                        statusBusy = true
                        statusError = nil
                        Task {
                            do { activity = try await model.activityStatus(outcome.activityID) }
                            catch { statusError = error.localizedDescription }
                            statusBusy = false
                        }
                    }
                    .disabled(statusBusy)
                    if statusBusy { ProgressView().controlSize(.small) }
                }
                if let activity {
                    Text(activityLine(activity))
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let raw = activity.attr("downloadUrl"), let url = URL(string: raw) {
                        Link("Download Apple result CSV", destination: url)
                            .font(.callout)
                    }
                }
                if let statusError {
                    Text(statusError).foregroundStyle(.red).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The polled activity rendered like abctl's `status activity` printKV block.
    private func activityLine(_ activity: Resource) -> String {
        var line = "Status: " + (activity.attr("status") ?? "unknown")
        if let sub = activity.attr("subStatus"), !sub.isEmpty { line += " (\(sub))" }
        if let created = activity.attr("createdDateTime"), !created.isEmpty { line += " — created \(created)" }
        if let completed = activity.attr("completedDateTime"), !completed.isEmpty { line += " — completed \(completed)" }
        return line
    }

    /// The gated device write, spelled out before it happens — same argv builder the client
    /// runs, so switching Assign/Unassign or the server rewrites the line in step with the
    /// button. No cwd: assignment is a pure tenant call that resolves nothing from a `gitops/`
    /// tree, and a `cd` here would imply a workspace matters when it doesn't.
    ///
    /// Withheld until a server is resolved, mirroring the button's own `serverID.isEmpty` guard.
    /// The picker is empty on open, and stays empty for good if the fetch failed — previewing
    /// `--server ''` there would put a live copy button next to a command that cannot run, on the
    /// one surface whose entire promise is "paste this and get the same effect".
    @ViewBuilder private var commandPreview: some View {
        if serverID.isEmpty {
            Text("Choose an MDM server to see the exact abctl command this runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        } else {
            CommandPreview(argv: model.previewArgv(
                            AbctlClient.assignArgs(serials: serials, server: serverID, unassign: unassign)),
                           caption: "\(unassign ? "Unassign" : "Assign") runs exactly this; --yes is the confirmation that button gives.")
        }
    }

    private var footer: some View {
        HStack {
            if isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Button(outcome == nil ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(unassign ? "Unassign" : "Assign") {
                isBusy = true
                errorText = nil
                Task {
                    do {
                        if unassign {
                            outcome = try await model.unassignDevices(serials, server: serverID)
                        } else {
                            outcome = try await model.assignDevices(serials, server: serverID)
                        }
                    } catch {
                        errorText = error.localizedDescription
                    }
                    isBusy = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || outcome != nil || serverID.isEmpty || serials.isEmpty)
        }
    }
}
