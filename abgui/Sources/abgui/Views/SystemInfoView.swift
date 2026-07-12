// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct SystemHealthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Connection") {
                switch model.connection {
                case .connected(let version, let identity):
                    LabeledContent("abctl", value: version.version)
                    LabeledContent("Go", value: version.goVersion)
                    LabeledContent("Commit", value: version.commit ?? "development build")
                    LabeledContent("Tenant", value: identity?.clientID ?? "not authenticated")
                    LabeledContent("API", value: identity?.apiBase ?? "—")
                    LabeledContent("Token expires", value: identity?.tokenExpires ?? "—")
                    LabeledContent("Capabilities", value: String(version.capabilities.count))
                case .failed(let error): Text(error).foregroundStyle(.red)
                case .checking: ProgressView("Checking…")
                case .unknown: Text("Not checked")
                }
            }
            Section("Cached inventory") {
                LabeledContent("Configurations", value: String(model.configurations.count))
                LabeledContent("Blueprints", value: String(model.blueprints.count))
                LabeledContent("Organization devices", value: String(model.devices.count))
                LabeledContent("Enrolled devices", value: String(model.mdmDevices.count))
                LabeledContent("MDM servers", value: String(model.mdmServers.count))
                LabeledContent("OS releases", value: String(model.osReleases.count))
            }
            Section("Product boundary") {
                Text("Apple Business and its built-in device management service. Legacy DEP and external-MDM content-token/VPP operation are intentionally unsupported.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("System Health")
        .toolbar { Button("Recheck") { Task { await model.check() } } }
    }
}

struct WhatsNewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Upcoming release").font(.title.bold())
                feature("Apple software releases", "Browse managed, public, and Rapid Security Response catalogs and compare them with last-reported device posture.", "apple.logo")
                feature("Actionable assignment results", "See completion status and open Apple's detailed result CSV for device assignment activities.", "list.bullet.clipboard")
                feature("Operational confidence", "System Health summarizes the bundled CLI, tenant connection, capabilities, and cached inventory.", "stethoscope")
                feature("Clearer product scope", "Apple Business built-in management stays first-class; legacy DEP and external-MDM VPP paths remain intentionally excluded.", "checkmark.shield")
            }.padding().frame(maxWidth: 720, alignment: .leading)
        }.navigationTitle("What’s New")
    }

    private func feature(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).frame(width: 30).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline); Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}
