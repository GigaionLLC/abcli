// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'json.dart';
import 'resource.dart';

// Typed payloads for the singular `get …` / `status …` inspection commands (abctl
// Phase A surface; shapes defined by internal/cli/inspect.go, get.go, manage.go).
// Each entity still travels as an open `Resource` attribute bag — these classes exist
// only where abctl wraps resources in a composite object ({device, assignedServer,
// appleCare}, blueprint relationships, the status-device report) that a bare
// `Resource`/`List<Resource>` can't express. Plain-resource details (user, app, package,
// activity) decode straight to `Resource` and need nothing here.
//
// The optional-vs-empty distinction below is load-bearing and is the reason these decode
// through `asList` rather than a defaulted reader: `appleCare`, `members` and `devices` are
// ABSENT when the caller did not pass the opt-in flag and EMPTY when the flag was passed and
// the answer was nothing. A sheet that collapsed the two would report "no coverage records"
// for a device nobody asked about.

/// `get device <x> [--applecare] --json` — the org device, its assigned MDM server,
/// and AppleCare coverage records.
class DeviceDetail {
  final Resource device;

  /// null unless the device status is ASSIGNED.
  final Resource? assignedServer;

  /// null without --applecare; `[]` = no coverage records.
  final List<Resource>? appleCare;

  const DeviceDetail({
    this.device = const Resource(),
    this.assignedServer,
    this.appleCare,
  });

  factory DeviceDetail.fromJson(Map<String, dynamic> json) => DeviceDetail(
    device: Resource.fromJson(asMapOr(json, 'device')),
    assignedServer: _resourceOrNull(json, 'assignedServer'),
    appleCare: _resourceListOrNull(json, 'appleCare'),
  );

  @override
  bool operator ==(Object other) =>
      other is DeviceDetail &&
      other.device == device &&
      other.assignedServer == assignedServer &&
      _resourcesEqual(other.appleCare, appleCare);

  @override
  int get hashCode =>
      Object.hash(device, assignedServer, appleCare?.length ?? -1);
}

/// `get mdmdevice <x> --json` — the built-in-MDM device + its last-reported posture
/// details (a second resource whose attributes carry osVersion, isFileVaultEnabled,
/// isFirewallEnabled, storage*Capacity, lock/erase/lost-mode, lastCheckInDateTime).
class MDMDeviceDetail {
  final Resource device;
  final Resource details;

  const MDMDeviceDetail({
    this.device = const Resource(),
    this.details = const Resource(),
  });

  factory MDMDeviceDetail.fromJson(Map<String, dynamic> json) =>
      MDMDeviceDetail(
        device: Resource.fromJson(asMapOr(json, 'device')),
        details: Resource.fromJson(asMapOr(json, 'details')),
      );

  @override
  bool operator ==(Object other) =>
      other is MDMDeviceDetail &&
      other.device == device &&
      other.details == details;

  @override
  int get hashCode => Object.hash(device, details);
}

/// `get usergroup <x> [--members] --json` — the group plus member emails.
class UserGroupDetail {
  final Resource group;

  /// null without --members; sorted emails (member id fallback).
  final List<String>? members;

  const UserGroupDetail({this.group = const Resource(), this.members});

  factory UserGroupDetail.fromJson(Map<String, dynamic> json) =>
      UserGroupDetail(
        group: Resource.fromJson(asMapOr(json, 'group')),
        members: asStringList(json, 'members'),
      );

  @override
  bool operator ==(Object other) =>
      other is UserGroupDetail &&
      other.group == group &&
      listEquals(other.members, members);

  @override
  int get hashCode => Object.hash(group, members?.length ?? -1);
}

/// `get mdmserver <x> [--devices] --json` — the server plus its assigned devices.
class MDMServerDetail {
  final Resource server;

  /// null without --devices; sorted serials (device id fallback).
  final List<String>? devices;

  /// null without --devices.
  final int? deviceCount;

  const MDMServerDetail({
    this.server = const Resource(),
    this.devices,
    this.deviceCount,
  });

  factory MDMServerDetail.fromJson(Map<String, dynamic> json) =>
      MDMServerDetail(
        server: Resource.fromJson(asMapOr(json, 'server')),
        devices: asStringList(json, 'devices'),
        deviceCount: asInt(json, 'deviceCount'),
      );

  @override
  bool operator ==(Object other) =>
      other is MDMServerDetail &&
      other.server == server &&
      other.deviceCount == deviceCount &&
      listEquals(other.devices, devices);

  @override
  int get hashCode => Object.hash(server, deviceCount, devices?.length ?? -1);
}

/// `get blueprint <x> --json` — the blueprint + member counts, the app ids (to
/// cross-reference `get apps`), the built-in-MDM Apps & Books license signal, and
/// all six member collections resolved to human names.
class BlueprintDetail {
  final Resource blueprint;
  final int configs;
  final int apps;
  final int devices;
  final List<String> appIds;
  final bool appLicenseDeficient;

  /// Relationship → resolved member names (configs/apps/packages/groups → name,
  /// devices → serial, users → email). Keys are Apple's relationship names.
  final Map<String, List<String>> relationships;

  const BlueprintDetail({
    this.blueprint = const Resource(),
    this.configs = 0,
    this.apps = 0,
    this.devices = 0,
    this.appIds = const <String>[],
    this.appLicenseDeficient = false,
    this.relationships = const <String, List<String>>{},
  });

  factory BlueprintDetail.fromJson(Map<String, dynamic> json) {
    final rels = <String, List<String>>{};
    final raw = asMap(json, 'relationships');
    if (raw != null) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is List) {
          rels[entry.key] = value.whereType<String>().toList(growable: false);
        }
      }
    }
    return BlueprintDetail(
      blueprint: Resource.fromJson(asMapOr(json, 'blueprint')),
      configs: asIntOr(json, 'configs', 0),
      apps: asIntOr(json, 'apps', 0),
      devices: asIntOr(json, 'devices', 0),
      appIds: asStringListOr(json, 'appIds'),
      appLicenseDeficient: asBoolOr(json, 'appLicenseDeficient', false),
      relationships: rels,
    );
  }

  /// The six relationship keys in abctl's display order (internal/cli/get.go blueprintRels).
  static const List<String> relationshipOrder = <String>[
    'configurations',
    'apps',
    'packages',
    'orgDevices',
    'users',
    'userGroups',
  ];

  @override
  bool operator ==(Object other) =>
      other is BlueprintDetail &&
      other.blueprint == blueprint &&
      other.configs == configs &&
      other.apps == apps &&
      other.devices == devices &&
      other.appLicenseDeficient == appLicenseDeficient &&
      listEquals(other.appIds, appIds) &&
      _relationshipsEqual(other.relationships, relationships);

  @override
  int get hashCode => Object.hash(
    blueprint,
    configs,
    apps,
    devices,
    appLicenseDeficient,
    appIds.length,
    relationships.length,
  );
}

/// `status device <x> --json` — one device end-to-end: assigned MDM server and
/// blueprint/config membership (desired-state / assignment intent) plus last-reported
/// built-in-MDM posture. NOT live on-device verification (the API can't report it).
class DeviceStatusReport {
  final Resource device;

  /// null when unassigned.
  final Resource? assignedServer;

  /// `[]` when no blueprint contains the device.
  final List<BlueprintCoverage> blueprints;

  /// null = not enrolled in built-in MDM.
  final MDMPosture? mdm;

  /// null without --applecare.
  final List<Resource>? appleCare;

  const DeviceStatusReport({
    this.device = const Resource(),
    this.assignedServer,
    this.blueprints = const <BlueprintCoverage>[],
    this.mdm,
    this.appleCare,
  });

  factory DeviceStatusReport.fromJson(
    Map<String, dynamic> json,
  ) => DeviceStatusReport(
    device: Resource.fromJson(asMapOr(json, 'device')),
    assignedServer: _resourceOrNull(json, 'assignedServer'),
    blueprints: asMapListOr(
      json,
      'blueprints',
    ).map(BlueprintCoverage.fromJson).toList(growable: false),
    // `mdm: null` is a real answer ("not enrolled"), so only a present OBJECT builds a
    // posture — otherwise a null would decode to an empty posture and the sheet would
    // report an enrolled device with no data instead of an unenrolled one.
    mdm: asMap(json, 'mdm') == null
        ? null
        : MDMPosture.fromJson(asMapOr(json, 'mdm')),
    appleCare: _resourceListOrNull(json, 'appleCare'),
  );

  @override
  bool operator ==(Object other) =>
      other is DeviceStatusReport &&
      other.device == device &&
      other.assignedServer == assignedServer &&
      other.mdm == mdm &&
      listEquals(other.blueprints, blueprints) &&
      _resourcesEqual(other.appleCare, appleCare);

  @override
  int get hashCode => Object.hash(
    device,
    assignedServer,
    mdm,
    blueprints.length,
    appleCare?.length ?? -1,
  );
}

/// One blueprint containing the device, with its configuration names.
class BlueprintCoverage {
  final String blueprint;
  final List<String> configurations;

  const BlueprintCoverage({
    this.blueprint = '',
    this.configurations = const <String>[],
  });

  factory BlueprintCoverage.fromJson(Map<String, dynamic> json) =>
      BlueprintCoverage(
        blueprint: asStringOr(json, 'blueprint', ''),
        configurations: asStringListOr(json, 'configurations'),
      );

  @override
  bool operator ==(Object other) =>
      other is BlueprintCoverage &&
      other.blueprint == blueprint &&
      listEquals(other.configurations, configurations);

  @override
  int get hashCode => Object.hash(blueprint, configurations.length);
}

/// The built-in-MDM section: {device, details} when enrolled (details may still be
/// null if the posture fetch failed), or {error} when listing MDM devices was
/// denied/unreachable — distinct from "not enrolled".
class MDMPosture {
  final Resource? device;
  final Resource? details;
  final String? error;

  const MDMPosture({this.device, this.details, this.error});

  factory MDMPosture.fromJson(Map<String, dynamic> json) => MDMPosture(
    device: _resourceOrNull(json, 'device'),
    details: _resourceOrNull(json, 'details'),
    error: asString(json, 'error'),
  );

  @override
  bool operator ==(Object other) =>
      other is MDMPosture &&
      other.device == device &&
      other.details == details &&
      other.error == error;

  @override
  int get hashCode => Object.hash(device, details, error);
}

/// `assign`/`unassign … --yes --json` — the accepted orgDeviceActivity (Apple processes
/// assignment asynchronously; the activity id is what abgui polls via `status activity`).
class ActivityOutcome {
  /// assign | unassign.
  final String action;
  final String server;
  final int devices;
  final String activityID;

  /// Final status — only present with --wait (abgui polls instead).
  final String? status;

  /// Only present with --wait.
  final String? subStatus;

  const ActivityOutcome({
    this.action = '',
    this.server = '',
    this.devices = 0,
    this.activityID = '',
    this.status,
    this.subStatus,
  });

  factory ActivityOutcome.fromJson(
    Map<String, dynamic> json,
  ) => ActivityOutcome(
    action: asStringOr(json, 'action', ''),
    server: asStringOr(json, 'server', ''),
    devices: asIntOr(json, 'devices', 0),
    // Wire key is `activityId`; the id is the whole point of the document (it is what
    // `status activity` polls), so it keeps the fuller name on this side.
    activityID: asStringOr(json, 'activityId', ''),
    status: asString(json, 'status'),
    subStatus: asString(json, 'subStatus'),
  );

  @override
  bool operator ==(Object other) =>
      other is ActivityOutcome &&
      other.action == action &&
      other.server == server &&
      other.devices == devices &&
      other.activityID == activityID &&
      other.status == status &&
      other.subStatus == subStatus;

  @override
  int get hashCode =>
      Object.hash(action, server, devices, activityID, status, subStatus);
}

Resource? _resourceOrNull(Map<String, dynamic> json, String key) {
  final map = asMap(json, key);
  return map == null ? null : Resource.fromJson(map);
}

List<Resource>? _resourceListOrNull(Map<String, dynamic> json, String key) {
  final list = asMapList(json, key);
  return list?.map(Resource.fromJson).toList(growable: false);
}

bool _resourcesEqual(List<Resource>? a, List<Resource>? b) => listEquals(a, b);

bool _relationshipsEqual(
  Map<String, List<String>> a,
  Map<String, List<String>> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!listEquals(entry.value, b[entry.key])) return false;
  }
  return true;
}
