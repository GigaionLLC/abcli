// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'json.dart';

// Port note: Swift nests `Verification`, `Verification.Mismatch` and `Phase` inside
// `ApplyResult`. Dart has no nested types, so they are top-level here as [Verification],
// [VerificationMismatch] and [ApplyPhase] — same fields, same decoding, same derived verdicts.

/// The result of `abctl sync --apply --json`: the per-item outcomes for the config phase
/// and the blueprint-membership phase, plus write/error/skip counts.
class ApplyResult {
  final ApplyPhase configs;
  final ApplyPhase blueprints;

  /// abctl's own post-apply verdict, from the `verification` key of the receipt.
  ///
  /// This is the STRUCTURED answer to "did the tenant end up matching git", and it was being
  /// thrown away: abgui reached the same conclusion by grepping stderr for the word FAILED,
  /// against a hand-maintained list of abctl's literal narration strings. Rewording one Go
  /// sentence silently downgraded the GUI's verdict to a generic "may not match git" — the
  /// same contract-drift that misclassified every non-config plan row. Null because an older
  /// abctl, or a run that died before verification, does not emit it.
  final Verification? verification;

  const ApplyResult({
    this.configs = const ApplyPhase(),
    this.blueprints = const ApplyPhase(),
    this.verification,
  });

  /// Both phases default to empty rather than throwing when a key is missing. abctl always
  /// emits both, but a receipt that lost one still carries the other's rows, and half a
  /// receipt beats an exception thrown at the end of a real tenant write.
  factory ApplyResult.fromJson(Map<String, dynamic> json) => ApplyResult(
    configs: ApplyPhase.fromJson(asMapOr(json, 'configs')),
    blueprints: ApplyPhase.fromJson(asMapOr(json, 'blueprints')),
    verification: asMap(json, 'verification') == null
        ? null
        : Verification.fromJson(asMapOr(json, 'verification')),
  );

  int get totalWrites => configs.writes + blueprints.writes;
  int get totalErrors => configs.errors + blueprints.errors;
  int get totalSkipped => configs.skipped + blueprints.skipped;
  List<OutcomeRow> get rows => [...configs.rows, ...blueprints.rows];

  @override
  bool operator ==(Object other) =>
      other is ApplyResult &&
      other.configs == configs &&
      other.blueprints == blueprints &&
      other.verification == verification;

  @override
  int get hashCode => Object.hash(configs, blueprints, verification);
}

/// The post-apply read-back verdict (internal/cli/phase1.go `verificationReport`).
class Verification {
  /// targeted | full | none.
  final String mode;

  /// Configs this run pushed to Apple.
  final int written;

  /// Of those, shown to match git (always 0 for mode "none").
  final int verified;

  final List<VerificationMismatch> mismatches;

  const Verification({
    this.mode = 'unknown',
    this.written = 0,
    this.verified = 0,
    this.mismatches = const <VerificationMismatch>[],
  });

  factory Verification.fromJson(Map<String, dynamic> json) => Verification(
    mode: asStringOr(json, 'mode', 'unknown'),
    written: asIntOr(json, 'written', 0),
    verified: asIntOr(json, 'verified', 0),
    mismatches: asMapListOr(
      json,
      'mismatches',
    ).map(VerificationMismatch.fromJson).toList(growable: false),
  );

  /// True when abctl positively established that something did NOT land. Distinct from
  /// "not everything was checked": `--verify=none` verifies nothing and is not a failure.
  bool get hasMismatches => mismatches.isNotEmpty;

  /// Writes abctl could not reach a verdict on — verified and mismatched are the two things
  /// it DID decide, so anything left over was never established either way.
  int get unchecked {
    final remainder = written - verified - mismatches.length;
    return remainder < 0 ? 0 : remainder;
  }

  /// The one-line verdict, in abgui's own words rather than scraped from abctl's.
  String get headline {
    if (hasMismatches) {
      final lost = mismatches.where((m) => m.observed).length;
      if (lost > 0) {
        return '$lost of $written written configuration(s) did not land on '
            'Apple Business.';
      }
      return '${mismatches.length} of $written written configuration(s) '
          'could not be checked.';
    }
    if (mode == 'none') return 'Writes were not verified (--verify=none).';
    return '$verified written configuration(s) confirmed on Apple Business.';
  }

  @override
  bool operator ==(Object other) =>
      other is Verification &&
      other.mode == mode &&
      other.written == written &&
      other.verified == verified &&
      listEquals(other.mismatches, mismatches);

  @override
  int get hashCode => Object.hash(mode, written, verified, mismatches.length);
}

/// One configuration the read-back could not confirm.
class VerificationMismatch {
  final String name;
  final String detail;

  /// true  → abctl READ the config and the bytes differ (the write did not land).
  /// false → abctl could not compare it, which says nothing about the write.
  /// abctl keeps these apart deliberately; collapsing them would report a network failure
  /// as a lost write.
  final bool observed;

  const VerificationMismatch({
    this.name = '',
    this.detail = '',
    this.observed = false,
  });

  factory VerificationMismatch.fromJson(
    Map<String, dynamic> json,
  ) => VerificationMismatch(
    name: asStringOr(json, 'name', ''),
    detail: asStringOr(json, 'detail', ''),
    // Defaults to false — "not established" — because the whole point of the flag is that
    // abgui must not claim a write was lost unless abctl said it observed that.
    observed: asBoolOr(json, 'observed', false),
  );

  @override
  bool operator ==(Object other) =>
      other is VerificationMismatch &&
      other.name == name &&
      other.detail == detail &&
      other.observed == observed;

  @override
  int get hashCode => Object.hash(name, detail, observed);
}

/// One reconcile phase (reconcile.Result / reconcile.BlueprintResult share this shape).
class ApplyPhase {
  final List<OutcomeRow> outcomes;
  final int writes;
  final int errors;
  final int skipped;

  const ApplyPhase({
    this.outcomes = const <OutcomeRow>[],
    this.writes = 0,
    this.errors = 0,
    this.skipped = 0,
  });

  factory ApplyPhase.fromJson(Map<String, dynamic> json) => ApplyPhase(
    outcomes: asMapListOr(
      json,
      'outcomes',
    ).map(OutcomeRow.fromJson).toList(growable: false),
    writes: asIntOr(json, 'writes', 0),
    errors: asIntOr(json, 'errors', 0),
    skipped: asIntOr(json, 'skipped', 0),
  );

  List<OutcomeRow> get rows => outcomes;

  @override
  bool operator ==(Object other) =>
      other is ApplyPhase &&
      other.writes == writes &&
      other.errors == errors &&
      other.skipped == skipped &&
      listEquals(other.outcomes, outcomes);

  @override
  int get hashCode => Object.hash(writes, errors, skipped, outcomes.length);
}

/// A unified apply outcome. Config outcomes carry `name`; blueprint outcomes carry
/// `blueprint` (+ optional `config`) — folded into `name` so one row type covers both.
class OutcomeRow {
  final String name;
  final String action;

  /// done | skipped | error.
  final String status;
  final String detail;
  final String? archive;

  const OutcomeRow({
    this.name = '',
    this.action = '',
    this.status = '',
    this.detail = '',
    this.archive,
  });

  factory OutcomeRow.fromJson(Map<String, dynamic> json) {
    final name = asString(json, 'name');
    return OutcomeRow(
      action: asStringOr(json, 'action', ''),
      status: asStringOr(json, 'status', ''),
      detail: asStringOr(json, 'detail', ''),
      archive: asString(json, 'archive'),
      // A blueprint row names its subject with `blueprint` (+ `config` for a member row);
      // folding both spellings into `name` here is what lets one row type — and one table —
      // report the config phase and the membership phase together.
      name:
          name ??
          (() {
            final blueprint = asStringOr(json, 'blueprint', '');
            final config = asString(json, 'config');
            return config == null ? blueprint : '$blueprint / $config';
          })(),
    );
  }

  String get id => '$action:$name:$detail';
  bool get failed => status == 'error';

  @override
  bool operator ==(Object other) =>
      other is OutcomeRow &&
      other.name == name &&
      other.action == action &&
      other.status == status &&
      other.detail == detail &&
      other.archive == archive;

  @override
  int get hashCode => Object.hash(name, action, status, detail, archive);

  @override
  String toString() => 'OutcomeRow($action $name → $status)';
}
