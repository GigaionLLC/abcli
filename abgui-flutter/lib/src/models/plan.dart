// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'json.dart';

/// The 3-way plan from `abctl diff --json` (== `sync --dry-run --json`): what a reconcile
/// would change. An empty plan means git and the tenant agree (no drift).
class Plan {
  final List<ConfigChange> configs;
  final List<BlueprintChange> blueprints;

  const Plan({
    this.configs = const <ConfigChange>[],
    this.blueprints = const <BlueprintChange>[],
  });

  /// Tolerates null/absent (older abctl builds emitted null for empty lists).
  factory Plan.fromJson(Map<String, dynamic> json) => Plan(
    configs: asMapListOr(
      json,
      'configs',
    ).map(ConfigChange.fromJson).toList(growable: false),
    blueprints: asMapListOr(
      json,
      'blueprints',
    ).map(BlueprintChange.fromJson).toList(growable: false),
  );

  bool get isEmpty => configs.isEmpty && blueprints.isEmpty;
  int get changeCount => configs.length + blueprints.length;
  int get actionableChangeCount =>
      configs.length + blueprints.where((b) => b.isActionable).length;
  int get blockedChangeCount => changeCount - actionableChangeCount;

  /// How many applicable rows write LOCAL files instead of the tenant: the pull family (a
  /// config that exists only in Apple, or one deleted there) and every blueprint adopt.
  int get localChangeCount =>
      configs.where((c) => c.isLocal).length +
      blueprints.where((b) => b.isActionable && b.isAdopt).length;

  @override
  bool operator ==(Object other) =>
      other is Plan &&
      listEquals(other.configs, configs) &&
      listEquals(other.blueprints, blueprints);

  @override
  int get hashCode => Object.hash(configs.length, blueprints.length);
}

/// One CUSTOM_SETTING config change (reconcile.Item).
class ConfigChange {
  final String name;

  /// create-abm | update-abm | pull-git | pull-new-git | delete-abm | delete-git | conflict.
  final String action;
  final String detail;

  const ConfigChange({this.name = '', this.action = '', this.detail = ''});

  factory ConfigChange.fromJson(Map<String, dynamic> json) => ConfigChange(
    name: asStringOr(json, 'name', ''),
    action: asStringOr(json, 'action', ''),
    detail: asStringOr(json, 'detail', ''),
  );

  /// True when applying this row writes gitops/ rather than Apple Business — the pull family.
  /// (`delete-git` removes a local file because Apple no longer has the config.)
  bool get isLocal =>
      action == 'pull-git' ||
      action == 'pull-new-git' ||
      action == 'delete-git';

  String get id => '$action:$name';

  @override
  bool operator ==(Object other) =>
      other is ConfigChange &&
      other.name == name &&
      other.action == action &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(name, action, detail);

  @override
  String toString() => 'ConfigChange($action $name)';
}

/// One blueprint-membership change (reconcile.BlueprintItem).
class BlueprintChange {
  final String blueprint;
  final String? bpID;

  /// `<verb>-<collection>` for a member row (attach-config, detach-app, adopt-user, …) or a
  /// blueprint-level verb (blueprint-new, blueprint-adopt). This is matched by PREFIX, never
  /// by equality: abctl manages six member collections, and spelling only the `-config` pair
  /// silently classified every app/package/device/user/group row as blocked.
  final String action;
  final String? config;
  final String? configID;
  final String detail;

  const BlueprintChange({
    this.blueprint = '',
    this.bpID,
    this.action = '',
    this.config,
    this.configID,
    this.detail = '',
  });

  factory BlueprintChange.fromJson(Map<String, dynamic> json) =>
      BlueprintChange(
        blueprint: asStringOr(json, 'blueprint', ''),
        bpID: asString(json, 'bp_id'),
        action: asStringOr(json, 'action', ''),
        config: asString(json, 'config'),
        configID: asString(json, 'config_id'),
        detail: asStringOr(json, 'detail', ''),
      );

  bool get isAttach => action.startsWith('attach-');
  bool get isDetach => action.startsWith('detach-');

  /// True for the member-level `adopt-<collection>` rows only — `blueprint-adopt` is a
  /// reported-only row about the blueprint itself and deliberately does not match.
  bool get isAdopt => action.startsWith('adopt-');

  /// Mirrors reconcile.BlueprintItem.IsActionable: a create, a detach, or an adopt is always
  /// performable; an attach needs a resolved member id, without which the row is blocked
  /// until the member exists in Apple Business.
  bool get isActionable =>
      action == 'blueprint-new' ||
      isDetach ||
      isAdopt ||
      (isAttach && (configID ?? '').isNotEmpty);

  /// The abctl noun for this row's collection — the first argument to `abctl adopt`. Null for
  /// blueprint-level rows, which address no member.
  String? get memberKind {
    if (!(isAttach || isDetach || isAdopt)) return null;
    final dash = action.indexOf('-');
    if (dash < 0) return null;
    return action.substring(dash + 1);
  }

  String get id => '$action:$blueprint:${config ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is BlueprintChange &&
      other.blueprint == blueprint &&
      other.bpID == bpID &&
      other.action == action &&
      other.config == config &&
      other.configID == configID &&
      other.detail == detail;

  @override
  int get hashCode =>
      Object.hash(blueprint, bpID, action, config, configID, detail);

  @override
  String toString() => 'BlueprintChange($action $blueprint/${config ?? ''})';
}
