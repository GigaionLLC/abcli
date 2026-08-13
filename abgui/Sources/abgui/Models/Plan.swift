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
    /// How many applicable rows write LOCAL files instead of the tenant: the pull family (a
    /// config that exists only in Apple, or one deleted there) and every blueprint adopt.
    var localChangeCount: Int {
        configs.filter(\.isLocal).count + blueprints.filter { $0.isActionable && $0.isAdopt }.count
    }

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
    let action: String   // create-abm | update-abm | pull-git | pull-new-git | delete-abm | delete-git | conflict
    let detail: String

    /// True when applying this row writes gitops/ rather than Apple Business — the pull family.
    /// (`delete-git` removes a local file because Apple no longer has the config.)
    var isLocal: Bool { action == "pull-git" || action == "pull-new-git" || action == "delete-git" }

    var id: String { "\(action):\(name)" }
}

/// One blueprint-membership change (reconcile.BlueprintItem).
struct BlueprintChange: Decodable, Identifiable, Equatable {
    let blueprint: String
    let bpID: String?
    /// `<verb>-<collection>` for a member row (attach-config, detach-app, adopt-user, …) or a
    /// blueprint-level verb (blueprint-new, blueprint-adopt). This is matched by PREFIX, never
    /// by equality: abctl manages six member collections, and spelling only the `-config` pair
    /// silently classified every app/package/device/user/group row as blocked.
    let action: String
    let config: String?
    let configID: String?
    let detail: String

    var isAttach: Bool { action.hasPrefix("attach-") }
    var isDetach: Bool { action.hasPrefix("detach-") }
    /// True for the member-level `adopt-<collection>` rows only — `blueprint-adopt` is a
    /// reported-only row about the blueprint itself and deliberately does not match.
    var isAdopt: Bool { action.hasPrefix("adopt-") }

    /// Mirrors reconcile.BlueprintItem.IsActionable: a create, a detach, or an adopt is always
    /// performable; an attach needs a resolved member id, without which the row is blocked until
    /// the member exists in Apple Business.
    var isActionable: Bool {
        action == "blueprint-new" || isDetach || isAdopt || (isAttach && !(configID ?? "").isEmpty)
    }

    /// The abctl noun for this row's collection — the first argument to `abctl adopt`. nil for
    /// blueprint-level rows, which address no member.
    var memberKind: String? {
        guard let dash = action.firstIndex(of: "-"), action.hasPrefix("attach-") || action.hasPrefix("detach-") || isAdopt
        else { return nil }
        return String(action[action.index(after: dash)...])
    }

    enum CodingKeys: String, CodingKey {
        case blueprint, action, config, detail
        case bpID = "bp_id"
        case configID = "config_id"
    }

    var id: String { "\(action):\(blueprint):\(config ?? "")" }
}
