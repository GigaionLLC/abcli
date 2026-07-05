// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Observation

/// Top-level app state. `@MainActor` so every mutation SwiftUI observes happens on the
/// main thread; the actual work hops onto `ProcessRunner` (its own actor) and back.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case unknown
        case checking
        case connected(VersionInfo, WhoamiResult?)
        case failed(String)
    }

    // Connection
    var connection: Connection = .unknown
    /// Optional abctl context name (blank → abctl uses its own .env / current context).
    var context: String = ""

    // Browsed inventory (loaded lazily per screen)
    var configurations: [Resource] = []
    var blueprints: [Resource] = []
    var plan: Plan?

    // Read-only resources (Apple Business exposes these for reading only)
    var devices: [Resource] = []
    var users: [Resource] = []
    var userGroups: [Resource] = []
    var apps: [Resource] = []
    var packages: [Resource] = []
    var mdmServers: [Resource] = []
    var auditEvents: [Resource] = []
    var auditSince = "7d"

    // GitOps workspace (the dir containing gitops/) — required for diff / sync / archive.
    var repoRoot: URL?
    var applyResult: ApplyResult?
    var archiveEntries: [ArchiveEntry] = []

    // Per-screen UI state
    var isLoading = false
    var loadError: String?

    // Write state (v2)
    var isWriting = false
    var lastWriteError: String?

    /// Build a client for the current context + workspace, or nil if abctl isn't found.
    private func makeClient() -> AbctlClient? {
        guard let binary = AbctlLocator.resolve() else { return nil }
        var client = AbctlClient(runner: ProcessRunner(executable: binary))
        client.context = context.isEmpty ? nil : context
        client.repoRoot = repoRoot
        return client
    }

    /// Point at a GitOps workspace (the dir containing `gitops/`) and recompute drift.
    func setWorkspace(_ url: URL) {
        repoRoot = url
        plan = nil
        applyResult = nil
        archiveEntries = []
    }

    /// Scan the workspace's gitops/archive/ tree (pure filesystem — no abctl).
    func loadArchive() {
        guard let root = repoRoot else { archiveEntries = []; return }
        archiveEntries = ArchiveScanner.scan(root: root)
    }

    /// Roll back: restore an archived live version by replacing the live config with it
    /// (which archives the CURRENT live version first — a reversible undo).
    func restore(_ entry: ArchiveEntry) async -> Bool {
        guard let data = try? Data(contentsOf: entry.fileURL),
              let xml = String(data: data, encoding: .utf8) else {
            lastWriteError = "couldn't read the archived profile at \(entry.fileURL.lastPathComponent)."
            return false
        }
        return await replaceConfiguration(id: entry.configName, xml: xml)
    }

    /// Reconcile the tenant to the workspace git state. Returns true on a clean apply.
    func apply(prune: Bool, limitWrites: Int?) async -> Bool {
        guard let client = makeClient() else {
            lastWriteError = "abctl was not found in the app bundle."
            return false
        }
        isWriting = true
        lastWriteError = nil
        defer { isWriting = false }
        do {
            let result = try await client.syncApply(prune: prune, limitWrites: limitWrites)
            applyResult = result
            await loadPlan()           // refresh drift
            await loadConfigurations() // the tenant changed
            return result.totalErrors == 0
        } catch {
            lastWriteError = error.localizedDescription
            return false
        }
    }

    /// Verify the embedded abctl runs and read its version + (best-effort) identity.
    func check() async {
        connection = .checking
        guard let client = makeClient() else {
            connection = .failed("abctl was not found in the app bundle (Contents/Resources/abctl).")
            return
        }
        do {
            let version = try await client.version()
            let identity = try? await client.whoami() // no creds yet is a normal first run
            connection = .connected(version, identity)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    // MARK: loads (each spawns a fresh abctl; errors surface in loadError)

    func loadConfigurations() async { await run { self.configurations = try await $0.configurations() } }
    func loadBlueprints() async { await run { self.blueprints = try await $0.blueprints() } }
    func loadPlan() async { await run { self.plan = try await $0.plan() } }

    /// The currently-loaded rows for a read-only resource.
    func readItems(_ kind: ReadOnlyKind) -> [Resource] {
        switch kind {
        case .devices: return devices
        case .users: return users
        case .userGroups: return userGroups
        case .apps: return apps
        case .packages: return packages
        case .mdmServers: return mdmServers
        case .audit: return auditEvents
        }
    }

    /// Load a read-only resource (a live GET; never writes).
    func loadReadOnly(_ kind: ReadOnlyKind) async {
        await run { client in
            switch kind {
            case .devices: self.devices = try await client.devices()
            case .users: self.users = try await client.users()
            case .userGroups: self.userGroups = try await client.userGroups()
            case .apps: self.apps = try await client.apps()
            case .packages: self.packages = try await client.packages()
            case .mdmServers: self.mdmServers = try await client.mdmServers()
            case .audit: self.auditEvents = try await client.audit(since: self.auditSince)
            }
        }
    }

    /// Fetch a config's raw profile XML (used by the profile inspector / editor).
    func profile(for id: String) async throws -> String {
        guard let client = makeClient() else { throw AbctlError.cli("abctl not found in the app bundle.") }
        return try await client.configurationProfile(id)
    }

    // MARK: writes (v2) — each returns success so a sheet can dismiss; abctl is gated with
    // --yes, so the caller MUST show its own confirm first. Config writes refresh the list.

    func createConfiguration(name: String, xml: String) async -> Bool {
        let ok = await runWrite { _ = try await $0.createConfiguration(name: name, xml: Data(xml.utf8)) }
        if ok { await loadConfigurations() }
        return ok
    }

    func replaceConfiguration(id: String, xml: String) async -> Bool {
        let ok = await runWrite { _ = try await $0.replaceConfiguration(id: id, xml: Data(xml.utf8)) }
        if ok { await loadConfigurations() }
        return ok
    }

    func deleteConfiguration(id: String) async -> Bool {
        let ok = await runWrite { _ = try await $0.deleteConfiguration(id: id) }
        if ok { await loadConfigurations() }
        return ok
    }

    func attach(configID: String, blueprint: String) async -> Bool {
        await runWrite { _ = try await $0.attach(configID: configID, blueprint: blueprint) }
    }

    func detach(configID: String, blueprint: String) async -> Bool {
        await runWrite { _ = try await $0.detach(configID: configID, blueprint: blueprint) }
    }

    /// Shared write wrapper: toggles isWriting, clears/sets lastWriteError, returns success.
    private func runWrite(_ body: (AbctlClient) async throws -> Void) async -> Bool {
        guard let client = makeClient() else {
            lastWriteError = "abctl was not found in the app bundle."
            return false
        }
        isWriting = true
        lastWriteError = nil
        defer { isWriting = false }
        do {
            try await body(client)
            return true
        } catch {
            lastWriteError = error.localizedDescription
            return false
        }
    }

    /// Shared load wrapper: toggles isLoading, clears/sets loadError, runs `body`.
    private func run(_ body: (AbctlClient) async throws -> Void) async {
        guard let client = makeClient() else {
            loadError = "abctl was not found in the app bundle."
            return
        }
        isLoading = true
        loadError = nil
        do {
            try await body(client)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
