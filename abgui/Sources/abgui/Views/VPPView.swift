// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// One column of a VPP table.
struct VPPCol<T>: Identifiable {
    let title: String
    let value: (T) -> String
    var id: String { title }
}

/// A simple read-only column table for VPP rows (List-based → macOS 14.0-safe).
struct VPPTable<T: Identifiable>: View {
    let items: [T]
    let columns: [VPPCol<T>]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(columns) { column in
                    Text(column.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 5)
            Divider()
            List(items) { item in
                HStack(spacing: 12) {
                    ForEach(columns) { column in
                        Text(column.value(item))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// Apps & Books (VPP) — the license inventory. Read-only. Needs a content token (sToken)
/// from Apple Business Manager, held in memory for the session only; abgui shells out to
/// `abctl vpp …` (a separate service from the Business API).
struct VPPView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            banner
            if model.vppConnected {
                Picker("View", selection: $tab) {
                    Text("Assets").tag(0)
                    Text("Assignments").tag(1)
                    Text("Users").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(8)
                Divider()
                tabContent
            } else {
                connectForm(token: $model.vppToken)
            }
        }
        .navigationTitle("Apps & Books")
        .toolbar {
            ReadOnlyBadge()
            if model.vppConnected {
                Button { Task { await model.vppConnect() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { model.vppDisconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case 0:
            VPPTable(items: model.vppAssets, columns: [
                VPPCol(title: "Name", value: { $0.name ?? $0.adamId }),
                VPPCol(title: "Adam ID", value: { $0.adamId }),
                VPPCol(title: "Type", value: { $0.productType ?? "—" }),
                VPPCol(title: "Pricing", value: { $0.pricingParam ?? "—" }),
                VPPCol(title: "Available", value: { String($0.availableCount ?? 0) }),
                VPPCol(title: "Assigned", value: { String($0.assignedCount ?? 0) }),
                VPPCol(title: "Total", value: { String($0.totalCount ?? 0) }),
            ])
            .overlay { emptyOverlay(model.vppAssets.isEmpty, "No assets", "bag") }
        case 1:
            VPPTable(items: model.vppAssignments, columns: [
                VPPCol(title: "Adam ID", value: { $0.adamId }),
                VPPCol(title: "Pricing", value: { $0.pricingParam ?? "—" }),
                VPPCol(title: "Serial", value: { $0.serialNumber ?? "—" }),
                VPPCol(title: "Client User ID", value: { $0.clientUserId ?? "—" }),
            ])
            .overlay { emptyOverlay(model.vppAssignments.isEmpty, "No assignments", "person.crop.rectangle") }
        default:
            VPPTable(items: model.vppUsers, columns: [
                VPPCol(title: "Client User ID", value: { $0.clientUserId }),
                VPPCol(title: "Email", value: { $0.email ?? "—" }),
                VPPCol(title: "Status", value: { $0.status ?? "—" }),
            ])
            .overlay { emptyOverlay(model.vppUsers.isEmpty, "No users", "person.2") }
        }
    }

    @ViewBuilder private func emptyOverlay(_ isEmpty: Bool, _ title: String, _ symbol: String) -> some View {
        if isEmpty {
            ContentUnavailableView(title, systemImage: symbol)
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
            Text("Read-only").fontWeight(.semibold)
            Text("·").foregroundStyle(.tertiary)
            Text("Apps & Books (VPP) license inventory — a separate service. Nothing here mutates the tenant.")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }

    @ViewBuilder private func connectForm(token: Binding<String>) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bag.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
            Text("Connect to Apps & Books").font(.headline)
            Text("Paste a content token from Apple Business Manager → Apps and Books → download a content token. It is held in memory for this session only.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            SecureField("VPP content token (sToken)", text: token)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 440)
                .onSubmit { Task { await model.vppConnect() } }
            Button("Connect") { Task { await model.vppConnect() } }
                .keyboardShortcut(.defaultAction)
                .disabled(token.wrappedValue.isEmpty || model.vppLoading)
            if model.vppLoading { ProgressView().controlSize(.small) }
            if let error = model.vppError {
                Text(error).foregroundStyle(.red).font(.caption)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
