// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'json.dart';

/// The machine-readable result of a gated abctl write (abctl P4): what changed, the new
/// id, the archived pre-overwrite copy, and whether the local git tree was updated.
class WriteOutcome {
  /// create | replace | delete | attach | detach | adopt.
  final String action;
  final String name;
  final String? id;

  /// "done".
  final String status;
  final String? updatedDateTime;

  /// Path to the archived pre-overwrite copy (replace/delete).
  final String? archive;

  /// Target blueprint (attach/detach/adopt).
  final String? blueprint;

  final bool treeUpdated;

  /// Why the local gitops write failed even though the TENANT write succeeded. abctl emits
  /// this document only on tenant success, so a non-null value is a half-done write, not a
  /// failed one: Apple has the change, git does not, and the next diff will show the drift.
  /// Absent on older abctl builds, hence optional.
  final String? treeError;

  /// abctl's READ-BACK verdict for a create/replace: `confirmed`, `unconfirmed`, or
  /// `not-persisted` (`internal/reconcile/apply.go`). Empty for every other verb.
  ///
  /// **This is the field that answers "was a 2xx proof?", and the answer is no.** Apple
  /// accepts a POST/PATCH carrying an out-of-spec profile with a 200 and then silently
  /// declines to store it — the live bytes never move — so abctl re-reads the configuration
  /// after every create/replace and records what Apple actually kept. A `not-persisted`
  /// verdict makes abctl exit non-zero (this document is never emitted for it), which is why
  /// the value that reaches a GUI is `confirmed` or `unconfirmed`. The two are NOT the same
  /// claim and must not be drawn the same: [confirmedStored] is proof, and
  /// [unconfirmedWarning] is the absence of one.
  final String? verified;

  const WriteOutcome({
    this.action = '',
    this.name = '',
    this.id,
    this.status = '',
    this.updatedDateTime,
    this.archive,
    this.blueprint,
    this.treeUpdated = false,
    this.treeError,
    this.verified,
  });

  /// `treeUpdated` defaults to FALSE when the key is missing, which is the conservative
  /// direction: the field used to be reported as true unconditionally, and that is how a
  /// green attach left git untouched with nothing on screen saying so.
  factory WriteOutcome.fromJson(Map<String, dynamic> json) => WriteOutcome(
    action: asStringOr(json, 'action', ''),
    name: asStringOr(json, 'name', ''),
    id: asString(json, 'id'),
    status: asStringOr(json, 'status', ''),
    updatedDateTime: asString(json, 'updatedDateTime'),
    archive: asString(json, 'archive'),
    blueprint: asString(json, 'blueprint'),
    treeUpdated: asBoolOr(json, 'treeUpdated', false),
    treeError: asString(json, 'treeError'),
    verified: asString(json, 'verified'),
  );

  /// True only when abctl read the configuration back and Apple's stored bytes matched the
  /// ones that were sent. Anything else — including a missing field from an older abctl —
  /// is NOT proof, which is why this is a positive test rather than `verified != 'x'`.
  bool get confirmedStored => verified == 'confirmed';

  /// The sentence to show when abctl could not confirm the write landed.
  ///
  /// `unconfirmed` means the read-back gave no answer, NOT that the write failed: abctl
  /// deliberately leaves the baseline alone in that case so the next `diff` re-checks it. A UI
  /// that renders this as a failure would send an operator chasing a write that very likely
  /// succeeded; one that renders it as success repeats the incident this whole read-back
  /// exists for. So it is its own state, in its own words.
  String? get unconfirmedWarning {
    if (verified != 'unconfirmed') return null;
    return 'Apple accepted the write, but abctl could not read the profile back to confirm '
        'the bytes were stored. That is not evidence the write failed — the read-back itself '
        'gave no answer — but it is not proof it landed either. The git baseline was left '
        'alone on purpose, so the next diff re-checks this configuration.';
  }

  /// The sentence to show when a write landed on the tenant but not in git. Null when there
  /// is nothing to warn about — a fully-applied write, or one that never asked to touch the
  /// tree.
  String? get treeWarning {
    final error = treeError;
    if (treeUpdated || error == null || error.isEmpty) return null;
    return 'Apple Business was updated, but the local gitops/ tree was not: '
        '$error. Until git catches up this will keep showing as drift.';
  }

  @override
  bool operator ==(Object other) =>
      other is WriteOutcome &&
      other.action == action &&
      other.name == name &&
      other.id == id &&
      other.status == status &&
      other.updatedDateTime == updatedDateTime &&
      other.archive == archive &&
      other.blueprint == blueprint &&
      other.treeUpdated == treeUpdated &&
      other.treeError == treeError &&
      other.verified == verified;

  @override
  int get hashCode => Object.hash(
    action,
    name,
    id,
    status,
    updatedDateTime,
    archive,
    blueprint,
    treeUpdated,
    treeError,
    verified,
  );

  @override
  String toString() => 'WriteOutcome($action $name → $status)';
}
