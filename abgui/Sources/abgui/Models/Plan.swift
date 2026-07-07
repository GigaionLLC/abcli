// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The 3-way plan from `abctl diff --json` (== `sync --dry-run --json`): what a reconcile
/// would change. An empty plan means git and the tenant agree (no drift).
struct Plan: Decodable, Equatable {
    var configs: [ConfigChange]
    var blueprints: [BlueprintChange]

    var isEmpty: Bool { configs.isEmpty && blueprints.isEmpty }
    var changeCount: Int { configs.count + blueprints.count }
    var actionableChangeCount: Int { configs.count + blueprints.filter(\.isActionable).count }
    var blockedChangeCount: Int { changeCount - actionableChangeCount }

    enum CodingKeys: String, CodingKey { case configs, blueprints }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerate null/absent (older abctl builds emitted null for empty lists).
        configs = try c.decodeIfPresent([ConfigChange].self, forKey: .configs) ?? []
        blueprints = try c.decodeIfPresent([BlueprintChange].self, forKey: .blueprints) ?? []
    }

    init(configs: [ConfigChange] = [], blueprints: [BlueprintChange] = []) {
        self.configs = configs
        self.blueprints = blueprints
    }
}

/// One CUSTOM_SETTING config change (reconcile.Item).
struct ConfigChange: Decodable, Identifiable, Equatable {
    let name: String
    let action: String   // create-abm | update-abm | pull-git | delete-abm | conflict | …
    let detail: String

    var id: String { "\(action):\(name)" }
}

/// One blueprint-membership change (reconcile.BlueprintItem).
struct BlueprintChange: Decodable, Identifiable, Equatable {
    let blueprint: String
    let bpID: String?
    let action: String   // attach-config | detach-config | blueprint-new | blueprint-adopt
    let config: String?
    let configID: String?
    let detail: String
    var isActionable: Bool {
        action == "detach-config" || (action == "attach-config" && !(configID ?? "").isEmpty)
    }

    enum CodingKeys: String, CodingKey {
        case blueprint, action, config, detail
        case bpID = "bp_id"
        case configID = "config_id"
    }

    var id: String { "\(action):\(blueprint):\(config ?? "")" }
}
