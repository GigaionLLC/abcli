// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// The `abctl validate --json` report: the pre-sync check of the workspace's OWN files
// (gitops/lib/ profiles + the blueprint manifests that reference them). It is local and
// credential-free — nothing here comes from the tenant.
//
// Every mirror decodes defensively. abgui ships its own abctl, but a user can point at an
// older binary, and abctl's report gains keys over time; a verification screen that crashes
// on a missing key is worse than one that renders a slightly thinner report. So each field
// is `decodeIfPresent`'d with a safe default, and the counters/verdicts fall back to what
// the rows themselves say rather than to zero.

/// One finding on a profile: a stable machine `code` (see the table in docs) plus a
/// one-sentence human `message`.
struct ValidationIssue: Decodable, Identifiable, Hashable {
    var id: String { code + message }
    let code: String
    let message: String

    enum CodingKeys: String, CodingKey { case code, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// One `lib/*.mobileconfig` as validated. Warnings never fail a profile — only `errors` do.
struct ProfileReport: Decodable, Identifiable, Hashable {
    /// The path is unique within a run; a report that omits it still lists by file name.
    var id: String { path.isEmpty ? name : path }
    let name: String
    let path: String
    let bytes: Int
    let ok: Bool
    let identifier: String?
    let displayName: String?
    let payloadTypes: [String]
    let errors: [ValidationIssue]
    let warnings: [ValidationIssue]

    var errorCount: Int { errors.count }
    var warningCount: Int { warnings.count }
    /// Passed, but with something worth reading — the views' amber (not red, not green) row.
    var passedWithWarnings: Bool { ok && !warnings.isEmpty }

    enum CodingKeys: String, CodingKey {
        case name, path, bytes, ok, identifier, displayName, payloadTypes, errors, warnings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        payloadTypes = try c.decodeIfPresent([String].self, forKey: .payloadTypes) ?? []
        let decodedErrors = try c.decodeIfPresent([ValidationIssue].self, forKey: .errors) ?? []
        let decodedWarnings = try c.decodeIfPresent([ValidationIssue].self, forKey: .warnings) ?? []
        errors = decodedErrors
        warnings = decodedWarnings
        // `ok` means exactly "no errors" on the abctl side, so a payload without the key can
        // be answered from the rows instead of failing a profile that reported nothing wrong.
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? decodedErrors.isEmpty
    }

    init(name: String, path: String = "", bytes: Int = 0, ok: Bool = true,
         identifier: String? = nil, displayName: String? = nil, payloadTypes: [String] = [],
         errors: [ValidationIssue] = [], warnings: [ValidationIssue] = []) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.ok = ok
        self.identifier = identifier
        self.displayName = displayName
        self.payloadTypes = payloadTypes
        self.errors = errors
        self.warnings = warnings
    }
}

/// A finding about the tree rather than a single file — most valuably a blueprint that
/// references a configuration `lib/` doesn't have (which would fail mid-sync).
struct TreeIssue: Decodable, Identifiable, Hashable {
    var id: String { "\(level)/\(scope)/\(target ?? "")/\(code)/\(message)" }
    let level: String          // "error" | "warning"
    let scope: String          // "blueprints" | "lib"
    let target: String?        // blueprint name / file name
    let code: String
    let message: String

    var isError: Bool { level == "error" }

    enum CodingKeys: String, CodingKey { case level, scope, target, code, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An issue we can't classify is shown as an error: a verification tool must not
        // quietly downgrade something it doesn't understand.
        level = try c.decodeIfPresent(String.self, forKey: .level) ?? "error"
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    init(level: String, scope: String, target: String? = nil, code: String, message: String) {
        self.level = level
        self.scope = scope
        self.target = target
        self.code = code
        self.message = message
    }
}

/// The whole report. `ok` is abctl's verdict (and its exit code): no profile errors, no
/// error-level tree issues, and — when `$ABCTL_VALIDATOR` is set — a clean external run.
struct ValidationReport: Decodable, Hashable {
    let ok: Bool
    let libDir: String
    let checked: Int
    let passed: Int
    let failed: Int
    let warnings: Int          // profile warnings + warning-level tree issues
    let profiles: [ProfileReport]
    let treeIssues: [TreeIssue]
    let validator: String      // "built-in" | "external"
    let validatorCommand: String?
    let validatorExitCode: Int?
    let validatorOutput: String?

    /// Tree issues split by level — errors lead the sheet, warnings follow.
    var treeErrors: [TreeIssue] { treeIssues.filter(\.isError) }
    var treeWarnings: [TreeIssue] { treeIssues.filter { !$0.isError } }
    /// Every error-level finding: each profile error plus each error-level tree issue.
    var errorCount: Int { profiles.reduce(0) { $0 + $1.errors.count } + treeErrors.count }
    /// abctl's own warning total, named to pair with `errorCount` at a call site.
    var warningCount: Int { warnings }
    /// True when `$ABCTL_VALIDATOR` ran alongside the built-in structural pass.
    var usesExternalValidator: Bool { validator == "external" }
    /// True when that external validator is itself a reason the report failed. abctl folds a
    /// non-zero validator exit into `ok:false` WITHOUT touching `failed` or adding a tree
    /// issue, so this is the third — and otherwise invisible — way a report can be not-ok.
    var validatorFailed: Bool { (validatorExitCode ?? 0) != 0 }
    /// The number of things a human has to look at: failing files, broken tree references,
    /// and a failed external validator. Every route to `ok == false` is counted here, so a
    /// verdict of "not ok" can never render as "0 problem(s)".
    var problemCount: Int { failed + treeErrors.count + (validatorFailed ? 1 : 0) }

    enum CodingKeys: String, CodingKey {
        case ok, libDir, checked, passed, failed, warnings, profiles, treeIssues
        case validator, validatorCommand, validatorExitCode, validatorOutput
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libDir = try c.decodeIfPresent(String.self, forKey: .libDir) ?? ""
        let decodedProfiles = try c.decodeIfPresent([ProfileReport].self, forKey: .profiles) ?? []
        let decodedTreeIssues = try c.decodeIfPresent([TreeIssue].self, forKey: .treeIssues) ?? []
        profiles = decodedProfiles
        treeIssues = decodedTreeIssues
        // The totals are all derivable from the rows, so a payload that omits one still adds
        // up instead of reporting a confident zero. Each derives independently of the others.
        let derivedWarnings = decodedProfiles.reduce(0) { $0 + $1.warnings.count }
            + decodedTreeIssues.filter { !$0.isError }.count
        checked = try c.decodeIfPresent(Int.self, forKey: .checked) ?? decodedProfiles.count
        passed = try c.decodeIfPresent(Int.self, forKey: .passed) ?? decodedProfiles.filter(\.ok).count
        let decodedFailed = try c.decodeIfPresent(Int.self, forKey: .failed)
            ?? decodedProfiles.filter { !$0.ok }.count
        failed = decodedFailed
        warnings = try c.decodeIfPresent(Int.self, forKey: .warnings) ?? derivedWarnings
        validator = try c.decodeIfPresent(String.self, forKey: .validator) ?? "built-in"
        validatorCommand = try c.decodeIfPresent(String.self, forKey: .validatorCommand)
        let decodedExitCode = try c.decodeIfPresent(Int.self, forKey: .validatorExitCode)
        validatorExitCode = decodedExitCode
        validatorOutput = try c.decodeIfPresent(String.self, forKey: .validatorOutput)
        // Same rule abctl applies: clean files, no broken references, and a validator (if any)
        // that exited 0. Only used when the key is absent — abctl's verdict always wins.
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
            ?? (decodedFailed == 0 && !decodedTreeIssues.contains(where: \.isError)
                && (decodedExitCode ?? 0) == 0)
    }

    init(ok: Bool, libDir: String = "", checked: Int = 0, passed: Int = 0, failed: Int = 0,
         warnings: Int = 0, profiles: [ProfileReport] = [], treeIssues: [TreeIssue] = [],
         validator: String = "built-in", validatorCommand: String? = nil,
         validatorExitCode: Int? = nil, validatorOutput: String? = nil) {
        self.ok = ok
        self.libDir = libDir
        self.checked = checked
        self.passed = passed
        self.failed = failed
        self.warnings = warnings
        self.profiles = profiles
        self.treeIssues = treeIssues
        self.validator = validator
        self.validatorCommand = validatorCommand
        self.validatorExitCode = validatorExitCode
        self.validatorOutput = validatorOutput
    }
}
