// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The result of `abctl sync --apply --json`: the per-item outcomes for the config phase
/// and the blueprint-membership phase, plus write/error/skip counts.
struct ApplyResult: Decodable, Equatable {
    let configs: Phase
    let blueprints: Phase
    /// abctl's own post-apply verdict, from the `verification` key of the receipt.
    ///
    /// This is the STRUCTURED answer to "did the tenant end up matching git", and it was being
    /// thrown away: abgui reached the same conclusion by grepping stderr for the word FAILED,
    /// against a hand-maintained list of abctl's literal narration strings. Rewording one Go
    /// sentence silently downgraded the GUI's verdict to a generic "may not match git" — the
    /// same contract-drift that misclassified every non-config plan row. Optional because an
    /// older abctl, or a run that died before verification, does not emit it.
    let verification: Verification?

    var totalWrites: Int { configs.writes + blueprints.writes }
    var totalErrors: Int { configs.errors + blueprints.errors }
    var totalSkipped: Int { configs.skipped + blueprints.skipped }
    var rows: [OutcomeRow] { configs.rows + blueprints.rows }

    /// The post-apply read-back verdict (internal/cli/phase1.go `verificationReport`).
    struct Verification: Decodable, Equatable {
        let mode: String        // targeted | full | none
        let written: Int        // configs this run pushed to Apple
        let verified: Int       // of those, shown to match git (always 0 for mode "none")
        let mismatches: [Mismatch]

        /// True when abctl positively established that something did NOT land. Distinct from
        /// "not everything was checked": `--verify=none` verifies nothing and is not a failure.
        var hasMismatches: Bool { !mismatches.isEmpty }

        /// Writes abctl could not reach a verdict on — verified and mismatched are the two
        /// things it DID decide, so anything left over was never established either way.
        var unchecked: Int { max(0, written - verified - mismatches.count) }

        struct Mismatch: Decodable, Equatable {
            let name: String
            let detail: String
            /// true  → abctl READ the config and the bytes differ (the write did not land).
            /// false → abctl could not compare it, which says nothing about the write.
            /// abctl keeps these apart deliberately; collapsing them would report a network
            /// failure as a lost write.
            let observed: Bool
        }

        enum CodingKeys: String, CodingKey { case mode, written, verified, mismatches }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "unknown"
            written = try c.decodeIfPresent(Int.self, forKey: .written) ?? 0
            verified = try c.decodeIfPresent(Int.self, forKey: .verified) ?? 0
            mismatches = try c.decodeIfPresent([Mismatch].self, forKey: .mismatches) ?? []
        }

        /// The one-line verdict, in abgui's own words rather than scraped from abctl's.
        var headline: String {
            if hasMismatches {
                let lost = mismatches.filter(\.observed).count
                if lost > 0 {
                    return "\(lost) of \(written) written configuration(s) did not land on Apple Business."
                }
                return "\(mismatches.count) of \(written) written configuration(s) could not be checked."
            }
            if mode == "none" { return "Writes were not verified (--verify=none)." }
            return "\(verified) written configuration(s) confirmed on Apple Business."
        }
    }

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
