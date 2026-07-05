// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Observation

/// Top-level app state. `@MainActor` so every mutation SwiftUI observes happens on the
/// main thread; the actual work hops onto `ProcessRunner` (its own actor) and back.
@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle
        case checking
        case connected(VersionInfo, WhoamiResult?)
        case failed(String)
    }

    var status: Status = .idle
    /// Optional abctl context name (blank → abctl uses its own .env / current context).
    var context: String = ""

    /// Verify the embedded abctl runs, read its version/capabilities, and — if a tenant
    /// is configured — its identity. A whoami failure is tolerated (no creds yet is a
    /// normal first-run state), so the app still shows it found a working binary.
    func check() async {
        status = .checking
        guard let binary = AbctlLocator.resolve() else {
            status = .failed("abctl was not found in the app bundle (Contents/Resources/abctl).")
            return
        }
        var client = AbctlClient(runner: ProcessRunner(executable: binary))
        client.context = context.isEmpty ? nil : context
        do {
            let version = try await client.version()
            let identity = try? await client.whoami()
            status = .connected(version, identity)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
