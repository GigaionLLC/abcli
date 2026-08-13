// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The machine-readable result of a gated abctl write (abctl P4): what changed, the new
/// id, the archived pre-overwrite copy, and whether the local git tree was updated.
struct WriteOutcome: Decodable, Equatable {
    let action: String            // create | replace | delete | attach | detach | adopt
    let name: String
    let id: String?
    let status: String            // "done"
    let updatedDateTime: String?
    let archive: String?          // path to the archived pre-overwrite copy (replace/delete)
    let blueprint: String?        // target blueprint (attach/detach/adopt)
    let treeUpdated: Bool
    /// Why the local gitops write failed even though the TENANT write succeeded. abctl emits
    /// this document only on tenant success, so a non-nil value is a half-done write, not a
    /// failed one: Apple has the change, git does not, and the next diff will show the drift.
    /// Absent on older abctl builds, hence optional.
    let treeError: String?

    /// The sentence to show when a write landed on the tenant but not in git. nil when there is
    /// nothing to warn about — a fully-applied write, or one that never asked to touch the tree.
    var treeWarning: String? {
        guard !treeUpdated, let treeError, !treeError.isEmpty else { return nil }
        return "Apple Business was updated, but the local gitops/ tree was not: \(treeError). "
            + "Until git catches up this will keep showing as drift."
    }
}
