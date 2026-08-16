// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'json.dart';

// The `abctl validate --json` report: the pre-sync check of the workspace's OWN files
// (gitops/lib/ profiles + the blueprint manifests that reference them). It is local and
// credential-free — nothing here comes from the tenant.
//
// Every mirror decodes defensively. abgui ships its own abctl, but a user can point at an
// older binary, and abctl's report gains keys over time; a verification screen that crashes
// on a missing key is worse than one that renders a slightly thinner report. So each field
// has a safe default, and the counters/verdicts fall back to what the rows themselves say
// rather than to zero.

/// One finding on a profile: a stable machine `code` (see the table in docs) plus a
/// one-sentence human `message`.
class ValidationIssue {
  final String code;
  final String message;

  const ValidationIssue({this.code = '', this.message = ''});

  factory ValidationIssue.fromJson(Map<String, dynamic> json) =>
      ValidationIssue(
        code: asStringOr(json, 'code', ''),
        message: asStringOr(json, 'message', ''),
      );

  String get id => code + message;

  @override
  bool operator ==(Object other) =>
      other is ValidationIssue &&
      other.code == code &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'ValidationIssue($code)';
}

/// One `lib/*.mobileconfig` as validated. Warnings never fail a profile — only `errors` do.
class ProfileReport {
  final String name;
  final String path;
  final int bytes;
  final bool ok;
  final String? identifier;
  final String? displayName;
  final List<String> payloadTypes;
  final List<ValidationIssue> errors;
  final List<ValidationIssue> warnings;

  const ProfileReport({
    this.name = '',
    this.path = '',
    this.bytes = 0,
    this.ok = true,
    this.identifier,
    this.displayName,
    this.payloadTypes = const <String>[],
    this.errors = const <ValidationIssue>[],
    this.warnings = const <ValidationIssue>[],
  });

  factory ProfileReport.fromJson(Map<String, dynamic> json) {
    final decodedErrors = asMapListOr(
      json,
      'errors',
    ).map(ValidationIssue.fromJson).toList(growable: false);
    return ProfileReport(
      name: asStringOr(json, 'name', ''),
      path: asStringOr(json, 'path', ''),
      bytes: asIntOr(json, 'bytes', 0),
      identifier: asString(json, 'identifier'),
      displayName: asString(json, 'displayName'),
      payloadTypes: asStringListOr(json, 'payloadTypes'),
      errors: decodedErrors,
      warnings: asMapListOr(
        json,
        'warnings',
      ).map(ValidationIssue.fromJson).toList(growable: false),
      // `ok` means exactly "no errors" on the abctl side, so a payload without the key can
      // be answered from the rows instead of failing a profile that reported nothing wrong.
      ok: asBool(json, 'ok') ?? decodedErrors.isEmpty,
    );
  }

  /// The path is unique within a run; a report that omits it still lists by file name.
  String get id => path.isEmpty ? name : path;

  int get errorCount => errors.length;
  int get warningCount => warnings.length;

  /// Passed, but with something worth reading — the views' amber (not red, not green) row.
  bool get passedWithWarnings => ok && warnings.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ProfileReport &&
      other.name == name &&
      other.path == path &&
      other.bytes == bytes &&
      other.ok == ok &&
      other.identifier == identifier &&
      other.displayName == displayName &&
      listEquals(other.payloadTypes, payloadTypes) &&
      listEquals(other.errors, errors) &&
      listEquals(other.warnings, warnings);

  @override
  int get hashCode => Object.hash(
    name,
    path,
    bytes,
    ok,
    identifier,
    displayName,
    payloadTypes.length,
    errors.length,
    warnings.length,
  );

  @override
  String toString() => 'ProfileReport($name ok=$ok)';
}

/// A finding about the tree rather than a single file — most valuably a blueprint that
/// references a configuration `lib/` doesn't have (which would fail mid-sync).
class TreeIssue {
  /// "error" | "warning".
  final String level;

  /// "blueprints" | "lib".
  final String scope;

  /// Blueprint name / file name.
  final String? target;
  final String code;
  final String message;

  const TreeIssue({
    this.level = 'error',
    this.scope = '',
    this.target,
    this.code = '',
    this.message = '',
  });

  factory TreeIssue.fromJson(Map<String, dynamic> json) => TreeIssue(
    // An issue we can't classify is shown as an error: a verification tool must not
    // quietly downgrade something it doesn't understand.
    level: asStringOr(json, 'level', 'error'),
    scope: asStringOr(json, 'scope', ''),
    target: asString(json, 'target'),
    code: asStringOr(json, 'code', ''),
    message: asStringOr(json, 'message', ''),
  );

  String get id => '$level/$scope/${target ?? ''}/$code/$message';

  bool get isError => level == 'error';

  @override
  bool operator ==(Object other) =>
      other is TreeIssue &&
      other.level == level &&
      other.scope == scope &&
      other.target == target &&
      other.code == code &&
      other.message == message;

  @override
  int get hashCode => Object.hash(level, scope, target, code, message);

  @override
  String toString() => 'TreeIssue($level $code)';
}

/// The whole report. `ok` is abctl's verdict (and its exit code): no profile errors, no
/// error-level tree issues, and — when `$ABCTL_VALIDATOR` is set — a clean external run.
class ValidationReport {
  final bool ok;
  final String libDir;
  final int checked;
  final int passed;
  final int failed;

  /// Profile warnings + warning-level tree issues. Note the shared word: the report's
  /// `warnings` is this TOTAL, while a profile's `warnings` is an issue ARRAY. Same key,
  /// two shapes, which is exactly why the golden fixtures pin both.
  final int warnings;

  final List<ProfileReport> profiles;
  final List<TreeIssue> treeIssues;

  /// "built-in" | "external".
  final String validator;
  final String? validatorCommand;
  final int? validatorExitCode;
  final String? validatorOutput;

  const ValidationReport({
    required this.ok,
    this.libDir = '',
    this.checked = 0,
    this.passed = 0,
    this.failed = 0,
    this.warnings = 0,
    this.profiles = const <ProfileReport>[],
    this.treeIssues = const <TreeIssue>[],
    this.validator = 'built-in',
    this.validatorCommand,
    this.validatorExitCode,
    this.validatorOutput,
  });

  factory ValidationReport.fromJson(Map<String, dynamic> json) {
    final decodedProfiles = asMapListOr(
      json,
      'profiles',
    ).map(ProfileReport.fromJson).toList(growable: false);
    final decodedTreeIssues = asMapListOr(
      json,
      'treeIssues',
    ).map(TreeIssue.fromJson).toList(growable: false);
    // The totals are all derivable from the rows, so a payload that omits one still adds
    // up instead of reporting a confident zero. Each derives independently of the others.
    final derivedWarnings =
        decodedProfiles.fold<int>(0, (sum, p) => sum + p.warnings.length) +
        decodedTreeIssues.where((t) => !t.isError).length;
    final decodedFailed =
        asInt(json, 'failed') ?? decodedProfiles.where((p) => !p.ok).length;
    final decodedExitCode = asInt(json, 'validatorExitCode');
    return ValidationReport(
      libDir: asStringOr(json, 'libDir', ''),
      profiles: decodedProfiles,
      treeIssues: decodedTreeIssues,
      checked: asInt(json, 'checked') ?? decodedProfiles.length,
      passed:
          asInt(json, 'passed') ?? decodedProfiles.where((p) => p.ok).length,
      failed: decodedFailed,
      warnings: asInt(json, 'warnings') ?? derivedWarnings,
      validator: asStringOr(json, 'validator', 'built-in'),
      validatorCommand: asString(json, 'validatorCommand'),
      validatorExitCode: decodedExitCode,
      validatorOutput: asString(json, 'validatorOutput'),
      // Same rule abctl applies: clean files, no broken references, and a validator (if any)
      // that exited 0. Only used when the key is absent — abctl's verdict always wins.
      ok:
          asBool(json, 'ok') ??
          (decodedFailed == 0 &&
              !decodedTreeIssues.any((t) => t.isError) &&
              (decodedExitCode ?? 0) == 0),
    );
  }

  /// Tree issues split by level — errors lead the sheet, warnings follow.
  List<TreeIssue> get treeErrors =>
      treeIssues.where((t) => t.isError).toList(growable: false);
  List<TreeIssue> get treeWarnings =>
      treeIssues.where((t) => !t.isError).toList(growable: false);

  /// Every error-level finding: each profile error plus each error-level tree issue.
  int get errorCount =>
      profiles.fold<int>(0, (sum, p) => sum + p.errors.length) +
      treeErrors.length;

  /// abctl's own warning total, named to pair with [errorCount] at a call site.
  int get warningCount => warnings;

  /// True when `$ABCTL_VALIDATOR` ran alongside the built-in structural pass.
  bool get usesExternalValidator => validator == 'external';

  /// True when that external validator is itself a reason the report failed. abctl folds a
  /// non-zero validator exit into `ok:false` WITHOUT touching `failed` or adding a tree
  /// issue, so this is the third — and otherwise invisible — way a report can be not-ok.
  bool get validatorFailed => (validatorExitCode ?? 0) != 0;

  /// The number of things a human has to look at: failing files, broken tree references,
  /// and a failed external validator. Every route to `ok == false` is counted here, so a
  /// verdict of "not ok" can never render as "0 problem(s)".
  int get problemCount =>
      failed + treeErrors.length + (validatorFailed ? 1 : 0);

  @override
  bool operator ==(Object other) =>
      other is ValidationReport &&
      other.ok == ok &&
      other.libDir == libDir &&
      other.checked == checked &&
      other.passed == passed &&
      other.failed == failed &&
      other.warnings == warnings &&
      other.validator == validator &&
      other.validatorCommand == validatorCommand &&
      other.validatorExitCode == validatorExitCode &&
      other.validatorOutput == validatorOutput &&
      listEquals(other.profiles, profiles) &&
      listEquals(other.treeIssues, treeIssues);

  @override
  int get hashCode => Object.hash(
    ok,
    libDir,
    checked,
    passed,
    failed,
    warnings,
    validator,
    validatorCommand,
    validatorExitCode,
    validatorOutput,
    profiles.length,
    treeIssues.length,
  );
}
