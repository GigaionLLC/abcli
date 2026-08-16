// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'resource.dart';

/// One column of a read-only resource table.
///
/// The value is a function of the row rather than a key name because most columns are not one
/// key: they fall back (`serialNumber ?? id`), join (`firstName` + `lastName`), or flatten a
/// nested array (`roles[].role`). Naming a key would push all of that into the view, where it
/// would be written once per table and once more for the CSV export — and the CSV is exactly
/// where the two copies drifted apart before.
class ColumnSpec {
  final String header;
  final String Function(Resource) value;

  const ColumnSpec(this.header, this.value);

  String get id => header;
}

/// A live Apple Business resource abgui browses. The API exposes these for reading
/// only (users/groups are console/SCIM-managed; apps/packages/mdm-servers/audit are
/// inventory), so every screen is badged read-only — with ONE disclosed exception:
/// [devices] also carries the gated Assign to MDM… write (device→server assignment
/// is the API's only device write; it runs behind the assign sheet's explicit confirm, and
/// the devices badge reads "Read-only · assignment gated").
enum ReadOnlyKind {
  devices('devices'),
  mdmDevices('mdmDevices'),
  users('users'),
  userGroups('userGroups'),
  apps('apps'),
  packages('packages'),
  mdmServers('mdmServers'),
  audit('audit'),

  /// Not a screen. The Swift enum had no such case because a Swift `init(rawValue:)` returns
  /// nil and callers handled it; a Dart enum has no failable lookup, so [fromWire] needs
  /// somewhere to land. It exists so that a value restored from settings — or one an older
  /// build wrote — can never crash the sidebar, and it is deliberately kept out of
  /// [browsable] so it can never be presented as a screen either.
  unknown('unknown');

  const ReadOnlyKind(this.wire);

  /// The stable token: the Swift `rawValue`, used for persistence and as the row id.
  final String wire;

  /// Maps a persisted/wire token to a kind, answering [unknown] rather than throwing.
  static ReadOnlyKind fromWire(String value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return unknown;
  }

  /// The eight real screens, in sidebar order. This — not `values` — is what a menu iterates,
  /// because `values` now carries [unknown].
  static const List<ReadOnlyKind> browsable = <ReadOnlyKind>[
    devices,
    mdmDevices,
    users,
    userGroups,
    apps,
    packages,
    mdmServers,
    audit,
  ];

  String get id => wire;

  String get title => switch (this) {
    ReadOnlyKind.devices => 'Devices',
    ReadOnlyKind.mdmDevices => 'Enrolled Devices',
    ReadOnlyKind.users => 'Users',
    ReadOnlyKind.userGroups => 'User Groups',
    ReadOnlyKind.apps => 'Apps (catalog)',
    ReadOnlyKind.packages => 'Packages',
    ReadOnlyKind.mdmServers => 'MDM Servers',
    ReadOnlyKind.audit => 'Audit',
    ReadOnlyKind.unknown => 'Unknown',
  };

  /// The SF Symbol name the macOS app used. Kept as a STRING rather than translated to an
  /// `IconData` here so this layer stays free of widget imports (and unit-testable without a
  /// binding); the Flutter shell maps these names to icons at the one place it draws them.
  String get symbol => switch (this) {
    ReadOnlyKind.devices => 'laptopcomputer',
    ReadOnlyKind.mdmDevices => 'checkmark.shield',
    ReadOnlyKind.users => 'person.2',
    ReadOnlyKind.userGroups => 'person.3',
    ReadOnlyKind.apps => 'bag',
    ReadOnlyKind.packages => 'shippingbox',
    ReadOnlyKind.mdmServers => 'server.rack',
    ReadOnlyKind.audit => 'list.bullet.rectangle',
    ReadOnlyKind.unknown => 'questionmark',
  };

  /// A one-line note explaining WHY this is read-only / what it is.
  String get note => switch (this) {
    ReadOnlyKind.devices =>
      'Organization devices. Details shows each device\'s assigned MDM '
          'server; select rows to assign/unassign a server (gated).',
    ReadOnlyKind.mdmDevices =>
      'Devices enrolled in the built-in device management service, with '
          'their last-reported posture — not a live device query.',
    ReadOnlyKind.users =>
      'Managed users + their roles. Identity is console/SCIM-managed — the '
          'API is read-only.',
    ReadOnlyKind.userGroups =>
      'User groups. Created in the console or via federation/SCIM, not this '
          'API.',
    ReadOnlyKind.apps =>
      'The organization\'s app catalog (Business API /v1/apps). VPP license '
          'counts are under Apps & Books.',
    ReadOnlyKind.packages =>
      'Custom apps / packages. Needs the built-in-device-management '
          'permission.',
    ReadOnlyKind.mdmServers => 'MDM servers registered with Apple Business.',
    ReadOnlyKind.audit => 'Admin API audit events over the selected window.',
    ReadOnlyKind.unknown => '',
  };

  List<ColumnSpec> get columns => switch (this) {
    ReadOnlyKind.devices => <ColumnSpec>[
      ColumnSpec('Serial', (r) => r.attr('serialNumber') ?? r.id),
      ColumnSpec('Model', (r) => r.attr('deviceModel') ?? '—'),
      // No "OS" column: `osVersion` is BUILT-IN-MDM posture, not an orgDevices
      // attribute — every Go read of it comes off mdmDetails, and abctl's own
      // orgDevices table prints serial/family/model only. It was permanently "—",
      // in the table and in the CSV export. Enrolled Devices is where OS lives.
      ColumnSpec('Family', (r) => r.attr('productFamily') ?? '—'),
    ],
    ReadOnlyKind.mdmDevices => <ColumnSpec>[
      ColumnSpec('Serial', (r) => r.attr('serialNumber') ?? r.id),
      ColumnSpec('Name', (r) => r.attr('deviceName') ?? '—'),
      ColumnSpec('Family', (r) => r.attr('productFamily') ?? '—'),
      ColumnSpec('Enrolled User', (r) => r.attr('enrolledUserId') ?? '—'),
    ],
    ReadOnlyKind.users => <ColumnSpec>[
      ColumnSpec('Name', (r) {
        final name = [
          r.attr('firstName'),
          r.attr('lastName'),
        ].whereType<String>().join(' ');
        return name.isEmpty ? (r.attr('managedAppleAccount') ?? r.id) : name;
      }),
      // The attribute is `managedAppleAccount` — Apple emits nothing called
      // `managedAppleId`, and reading `email` first would quietly break the promise
      // this header makes.
      ColumnSpec(
        'Managed Apple ID',
        (r) => r.attr('managedAppleAccount') ?? r.attr('email') ?? '—',
      ),
      ColumnSpec('Roles', (r) {
        final roles = r.roleNames();
        return roles.isEmpty ? '—' : roles;
      }),
      ColumnSpec('Status', (r) => r.attr('status') ?? '—'),
    ],
    ReadOnlyKind.userGroups => <ColumnSpec>[
      ColumnSpec('Name', (r) => r.attr('name') ?? r.id),
      ColumnSpec('Type', (r) => r.attr('groupType') ?? '—'),
      ColumnSpec('Status', (r) => r.attr('status') ?? '—'),
    ],
    ReadOnlyKind.apps => <ColumnSpec>[
      ColumnSpec('Name', (r) => r.attr('name') ?? r.id),
      ColumnSpec('Bundle ID', (r) => r.attr('bundleId') ?? '—'),
      ColumnSpec('Version', (r) => r.attr('version') ?? '—'),
      ColumnSpec('Custom', (r) => r.attr('isCustomApp') ?? '—'),
    ],
    ReadOnlyKind.packages => <ColumnSpec>[
      ColumnSpec('Name', (r) => r.attr('name') ?? r.attr('bundleId') ?? r.id),
      ColumnSpec('Bundle ID', (r) => r.attr('bundleId') ?? '—'),
      ColumnSpec('Version', (r) => r.attr('version') ?? '—'),
    ],
    ReadOnlyKind.mdmServers => <ColumnSpec>[
      ColumnSpec('Name', (r) => r.attr('serverName') ?? r.id),
      ColumnSpec('Type', (r) => r.attr('serverType') ?? '—'),
      ColumnSpec('ID', (r) => r.id),
    ],
    ReadOnlyKind.audit => <ColumnSpec>[
      ColumnSpec(
        'Time',
        (r) => r.attr('eventTime') ?? r.attr('createdDateTime') ?? '—',
      ),
      ColumnSpec('Event', (r) => r.attr('eventType') ?? '—'),
      ColumnSpec(
        'Actor',
        (r) => r.attr('actorName') ?? r.attr('actorId') ?? '—',
      ),
    ],
    ReadOnlyKind.unknown => const <ColumnSpec>[],
  };
}
