// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The machine-readable result of a gated abctl write (abctl P4): what changed, the new
/// id, the archived pre-overwrite copy, and whether the local git tree was updated.
struct WriteOutcome: Decodable, Equatable {
    let action: String            // create | replace | delete | attach | detach
    let name: String
    let id: String?
    let status: String            // "done"
    let updatedDateTime: String?
    let archive: String?          // path to the archived pre-overwrite copy (replace/delete)
    let blueprint: String?        // target blueprint (attach/detach)
    let treeUpdated: Bool
}
