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
    var devices: [Resource] = []
    var plan: Plan?

    // Per-screen UI state
    var isLoading = false
    var loadError: String?

    /// Build a client for the current context, or nil if abctl can't be located.
    private func makeClient() -> AbctlClient? {
        guard let binary = AbctlLocator.resolve() else { return nil }
        var client = AbctlClient(runner: ProcessRunner(executable: binary))
        client.context = context.isEmpty ? nil : context
        return client
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
    func loadDevices() async { await run { self.devices = try await $0.devices() } }
    func loadPlan() async { await run { self.plan = try await $0.plan() } }

    /// Fetch a config's raw profile XML (used by the profile inspector).
    func profile(for id: String) async throws -> String {
        guard let client = makeClient() else { throw AbctlError.cli("abctl not found in the app bundle.") }
        return try await client.configurationProfile(id)
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
