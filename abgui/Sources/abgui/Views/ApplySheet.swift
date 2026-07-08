// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// The gated converge: `sync --apply`. Shows the applicable pending count, exposes
/// `--prune` and `--limit-writes`, streams progress, and keeps final outcomes in a
/// separate pane. The Apply button IS the human gate.
struct ApplySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var prune = true
    @State private var limitText = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apply to the tenant").font(.headline)
                Spacer()
                Button("Clear") { model.clearApplyOutput() }
                    .disabled(model.isWriting || (model.applyProgressLog.isEmpty && model.applyResult == nil && model.lastWriteError == nil))
            }

            if let plan = model.plan {
                Text(applySummary(plan))
                    .foregroundStyle(.secondary)
            }

            Toggle("Git source of truth", isOn: $model.gitSourceOfTruth)
                .onChange(of: model.gitSourceOfTruth) { _, enabled in
                    if enabled { prune = true }
                }
            if model.gitSourceOfTruth {
                Text("Apple Business will be changed to match gitops/, including deleting live-only configurations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Allow deletes / detaches (--prune)", isOn: $prune)
                .disabled(model.gitSourceOfTruth)
            HStack {
                Text("Limit writes")
                TextField("unlimited", text: $limitText)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                Text("(circuit breaker)").foregroundStyle(.secondary).font(.caption)
            }

            if model.isWriting || !model.applyProgressLog.isEmpty {
                logView(title: "Progress", lines: model.applyProgressLog)
            }

            if let result = model.applyResult {
                resultView(result)
            }
            if let error = model.lastWriteError {
                Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }

            HStack {
                if model.isWriting { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.applyResult == nil ? "Cancel" : "Exit") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    Task {
                        _ = await model.apply(prune: prune,
                                              limitWrites: Int(limitText.trimmingCharacters(in: .whitespaces)))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWriting || (model.plan?.actionableChangeCount ?? 0) == 0)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 440)
    }

    private func applySummary(_ plan: Plan) -> String {
        let writes = plan.actionableChangeCount
        let blocked = plan.blockedChangeCount
        if blocked == 0 {
            return "\(writes) pending change(s) can be applied to Apple Business."
        }
        if writes == 0 {
            return "\(blocked) blocked pending item(s) need their configuration created in Apple before they can attach."
        }
        return "\(writes) pending change(s) can be applied; \(blocked) dependent item(s) are blocked until their config has an Apple id."
    }

    @ViewBuilder private func logView(title: String, lines: [String]) -> some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if lines.isEmpty {
                            Text("Starting...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(lines.indices, id: \.self) { idx in
                            Text(lines[idx])
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(minHeight: 110, maxHeight: 150)
                .onChange(of: lines.count) { _, count in
                    if count > 0 { withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) } }
                }
            }
        } label: {
            Text(title)
        }
    }

    @ViewBuilder private func resultView(_ result: ApplyResult) -> some View {
        GroupBox("Results") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(result.totalWrites) write(s) - \(result.totalErrors) error(s) - \(result.totalSkipped) skipped")
                    .foregroundStyle(result.totalErrors > 0 ? .red : .green)
                if !result.rows.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(result.rows) { row in
                                OutcomeResultRow(row: row)
                                Divider()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OutcomeResultRow: View {
    let row: OutcomeRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
            Text(row.action)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.caption)
                    .textSelection(.enabled)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var iconName: String {
        switch row.status {
        case "error": return "xmark.circle"
        case "skipped": return "minus.circle"
        default: return "checkmark.circle"
        }
    }

    private var iconColor: Color {
        switch row.status {
        case "error": return .red
        case "skipped": return .secondary
        default: return .green
        }
    }
}
