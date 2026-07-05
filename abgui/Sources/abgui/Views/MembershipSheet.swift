// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Attach/detach a configuration to/from a blueprint. abctl handles idempotency (attach
/// merges; detach removes), and every write is gated with --yes — the buttons here are the
/// human confirmation.
struct MembershipSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let config: Resource

    @State private var blueprintID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Membership — \(config.attr("name") ?? config.id)").font(.headline)

            Picker("Blueprint", selection: $blueprintID) {
                Text("Select a blueprint…").tag(String?.none)
                ForEach(model.blueprints) { blueprint in
                    Text(blueprint.attr("name") ?? blueprint.id).tag(Optional(blueprint.id))
                }
            }

            if let error = model.lastWriteError {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button("Attach") {
                    Task { if await model.attach(configID: config.id, blueprint: blueprintID ?? "") { dismiss() } }
                }
                .disabled(blueprintID == nil || model.isWriting)

                Button("Detach", role: .destructive) {
                    Task { if await model.detach(configID: config.id, blueprint: blueprintID ?? "") { dismiss() } }
                }
                .disabled(blueprintID == nil || model.isWriting)

                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 440)
        .task {
            if model.blueprints.isEmpty { await model.loadBlueprints() }
        }
    }
}
