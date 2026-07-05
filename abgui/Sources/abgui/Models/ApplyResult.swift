// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The result of `abctl sync --apply --json`: the per-item outcomes for the config phase
/// and the blueprint-membership phase, plus write/error/skip counts.
struct ApplyResult: Decodable, Equatable {
    let configs: Phase
    let blueprints: Phase

    var totalWrites: Int { configs.writes + blueprints.writes }
    var totalErrors: Int { configs.errors + blueprints.errors }
    var totalSkipped: Int { configs.skipped + blueprints.skipped }
    var rows: [OutcomeRow] { configs.rows + blueprints.rows }

    /// One reconcile phase (reconcile.Result / reconcile.BlueprintResult share this shape).
    struct Phase: Decodable, Equatable {
        let outcomes: [OutcomeRow]
        let writes: Int
        let errors: Int
        let skipped: Int

        enum CodingKeys: String, CodingKey { case outcomes, writes, errors, skipped }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            outcomes = try c.decodeIfPresent([OutcomeRow].self, forKey: .outcomes) ?? []
            writes = try c.decodeIfPresent(Int.self, forKey: .writes) ?? 0
            errors = try c.decodeIfPresent(Int.self, forKey: .errors) ?? 0
            skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        }
        var rows: [OutcomeRow] { outcomes }
    }
}

/// A unified apply outcome. Config outcomes carry `name`; blueprint outcomes carry
/// `blueprint` (+ optional `config`) — folded into `name` so one row type covers both.
struct OutcomeRow: Decodable, Identifiable, Equatable {
    let name: String
    let action: String
    let status: String   // done | skipped | error
    let detail: String
    let archive: String?

    var id: String { "\(action):\(name):\(detail)" }
    var failed: Bool { status == "error" }

    enum CodingKeys: String, CodingKey {
        case name, action, status, detail, archive, blueprint, config
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        archive = try c.decodeIfPresent(String.self, forKey: .archive)
        if let name = try c.decodeIfPresent(String.self, forKey: .name) {
            self.name = name
        } else {
            let blueprint = try c.decodeIfPresent(String.self, forKey: .blueprint) ?? ""
            let config = try c.decodeIfPresent(String.self, forKey: .config)
            self.name = config.map { "\(blueprint) / \($0)" } ?? blueprint
        }
    }
}
