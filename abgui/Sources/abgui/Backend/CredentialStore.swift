// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Where abgui persists a pasted private key. abctl reads the EC key from a file PATH (see
/// internal/config), so a PEM the user pastes into Settings is written to a user-only file
/// under Application Support and the context stores that path. Files are `0600` inside a
/// `0700` directory; key material is never passed on argv, logged, or written to
/// contexts.yaml. Users who prefer to keep the key elsewhere can instead point a context at
/// an existing .pem on disk — this store is only for the paste path.
enum CredentialStore {
    /// ~/Library/Application Support/abgui/keys
    static var keysDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("abgui/keys", isDirectory: true)
    }

    /// Persist `pem` for `context`, returning the absolute path abctl should read. Overwrites
    /// any prior key for the same context (re-saving credentials is idempotent).
    @discardableResult
    static func writeKey(pem: String, context: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: keysDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let url = keysDir.appendingPathComponent("\(safeName(context)).pem")
        try pem.write(to: url, atomically: true, encoding: .utf8)
        // Tighten the final file to owner-only read/write (the atomic temp lived in the 0700 dir).
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// A filesystem-safe filename component from a user-chosen context name.
    static func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "default" : cleaned
    }
}
