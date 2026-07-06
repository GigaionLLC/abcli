// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import AppKit

/// Connection settings — enter an Apple Business API **Client ID** + **EC private key** and
/// save them as an abctl context (`~/.abctl/contexts.yaml`, `0600`). This is what resolves
/// "AB_CLIENT_ID not set": a GUI launched from Finder inherits no shell environment, so the
/// credentials live in the context store instead of `AB_*` env vars. The key is handed to
/// abctl as a file path — a pasted PEM is written to a user-only file under Application
/// Support; abgui mints the short-lived API token from it and nothing leaves the Mac.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var name = "default"
    @State private var clientID = ""
    @State private var keyEntry: KeyEntry = .paste
    @State private var pem = ""
    @State private var keyFilePath = ""
    @State private var apiBase = ""
    @State private var showAdvanced = false
    @State private var didSave = false

    enum KeyEntry: String, CaseIterable, Identifiable {
        case paste = "Paste PEM"
        case file = "Choose file"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            savedConnectionsSection
            connectionSection
            privateKeySection

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                TextField("API base URL", text: $apiBase,
                          prompt: Text("https://api-business.apple.com/v1/"))
                    .help("Leave blank for the standard Apple Business API endpoint.")
            }

            statusSection
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 600)
        .task { await model.loadContexts() }
    }

    // MARK: sections

    @ViewBuilder private var savedConnectionsSection: some View {
        Section("Saved connections") {
            if model.contexts.isEmpty {
                Text("No saved connections yet — fill in the fields below and Save & Connect.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                Picker("Current tenant", selection: currentSelection) {
                    ForEach(model.contexts, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Button("Load into form") { Task { await loadSelectedIntoForm() } }
                        .disabled(model.currentContext.isEmpty)
                    Spacer()
                    Button("Delete", role: .destructive) {
                        Task { await model.deleteConnection(model.currentContext) }
                    }
                    .disabled(model.currentContext.isEmpty)
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var connectionSection: some View {
        Section("Connection") {
            TextField("Name", text: $name)
                .help("A local label for this tenant (e.g. \"prod\"). Stored in ~/.abctl/contexts.yaml.")
            TextField("Client ID", text: $clientID,
                      prompt: Text("BUSINESSAPI.xxxxxxxx-xxxx-xxxx-…"))
                .help("From Apple Business Manager → Preferences → API. Not secret — it's an identifier.")
        }
    }

    @ViewBuilder private var privateKeySection: some View {
        Section("Private key (EC .pem)") {
            Picker("Provide key by", selection: $keyEntry) {
                ForEach(KeyEntry.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if keyEntry == .paste {
                TextEditor(text: $pem)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if pem.isEmpty {
                            Text("-----BEGIN PRIVATE KEY-----\n…\n-----END PRIVATE KEY-----")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                Text("Saved to \(CredentialStore.keysDir.path)/ with permissions 0600. The key never leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("Path to .pem", text: $keyFilePath).truncationMode(.middle)
                    Button("Choose…") { chooseKeyFile() }
                }
                Text("abctl reads the key from this path on each run — keep the file in place.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            if let error = model.settingsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            } else if didSave {
                Label(savedSummary, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout)
            }
            HStack {
                Spacer()
                if model.settingsBusy { ProgressView().controlSize(.small) }
                Button("Save & Connect") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.settingsBusy)
            }
        }
    }

    // MARK: actions

    /// The picker binds to the store's current context; changing it switches tenants.
    private var currentSelection: Binding<String> {
        Binding(get: { model.currentContext },
                set: { newValue in Task { await model.useConnection(newValue) } })
    }

    private var savedSummary: String {
        if case .connected(_, let identity?) = model.connection { return "Connected — \(identity.clientID)" }
        return "Saved."
    }

    private func save() async {
        let ok = await model.saveConnection(
            name: name,
            clientID: clientID,
            keyPEM: keyEntry == .paste ? pem : "",
            keyPath: keyEntry == .file ? keyFilePath : "",
            apiBase: apiBase
        )
        didSave = ok
        if ok { pem = "" } // don't keep key material in the editor after a successful save
    }

    private func loadSelectedIntoForm() async {
        let target = model.currentContext
        guard !target.isEmpty, let detail = await model.contextDetail(target) else { return }
        name = detail.name
        clientID = detail.context.clientID
        keyEntry = .file
        keyFilePath = detail.context.keyPath
        apiBase = detail.context.apiBase ?? ""
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Apple Business API EC private key (.pem)"
        if panel.runModal() == .OK, let url = panel.url { keyFilePath = url.path }
    }
}
