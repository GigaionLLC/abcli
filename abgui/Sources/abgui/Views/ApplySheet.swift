// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The gated converge: `sync --apply`. Shows the pending count, exposes `--prune` and
/// `--limit-writes` as explicit toggles (both off/unbounded by default, matching abctl),
/// and — after applying — the per-item outcomes. The Apply button IS the human gate.
struct ApplySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var prune = false
    @State private var limitText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply to the tenant").font(.headline)

            if let plan = model.plan {
                Text("\(plan.changeCount) pending change(s) will be written to Apple Business.")
                    .foregroundStyle(.secondary)
            }

            Toggle("Allow deletes / detaches (--prune)", isOn: $prune)
            HStack {
                Text("Limit writes")
                TextField("unlimited", text: $limitText)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                Text("(circuit breaker)").foregroundStyle(.secondary).font(.caption)
            }

            if let result = model.applyResult {
                resultView(result)
            }
            if let error = model.lastWriteError {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                if model.isWriting { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.applyResult == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { Task { _ = await model.apply(prune: prune, limitWrites: Int(limitText.trimmingCharacters(in: .whitespaces))) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWriting || (model.plan?.isEmpty ?? true))
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 240)
    }

    @ViewBuilder private func resultView(_ result: ApplyResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(result.totalWrites) write(s) · \(result.totalErrors) error(s) · \(result.totalSkipped) skipped")
                    .foregroundStyle(result.totalErrors > 0 ? .red : .green)
                if !result.rows.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(result.rows) { row in
                                HStack(spacing: 8) {
                                    Image(systemName: row.failed ? "xmark.circle" : "checkmark.circle")
                                        .foregroundStyle(row.failed ? .red : .green)
                                    Text(row.action).font(.system(.caption, design: .monospaced))
                                    Text(row.name).font(.caption)
                                    Spacer()
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
