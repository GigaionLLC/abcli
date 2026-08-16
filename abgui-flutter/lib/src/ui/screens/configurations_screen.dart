// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The configuration list, and the app's only surface that changes a tenant's profiles.
///
/// **This screen crossed from read-only to read-write, and the crossing is the whole story.**
/// The four controls it gained — New, Edit (→ `replace`), Delete, and the pre-flight that gates
/// the first two — reach a live Apple Business Manager tenant belonging to a real company. What
/// the Swift `ConfigurationsView` had and this deliberately does NOT reproduce:
///
///  * a Save that dismissed on success, discarding abctl's outcome document. `treeUpdated:false`
///    — Apple written, git not — arrives on a run that exits 0, so throwing the document away is
///    how a green write became a drift row nobody could connect to it days later. The dialogs
///    here stay open and render what abctl said;
///  * a write with no validation in front of it. Apple accepts an out-of-spec profile with a 2xx
///    and silently declines to store it, so "it worked" was never a thing the exit code could
///    say. See `ProfilePreflight`;
///  * Membership (attach / detach). That verb exists in `AbctlArgs` and in `AbctlClient`, and it
///    is deliberately absent from this toolbar: it belongs to the blueprint relationship and is
///    not part of this screen's phase. Its absence is a scope line, not an oversight.
///
/// Everything destructive is disabled without a GitOps workspace — see `configWriteBlocker` for
/// the failure that rule prevents.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/ui/dialogs/config_editor_dialog.dart';
import 'package:abgui/src/ui/dialogs/profile_dialog.dart';
import 'package:abgui/src/ui/screens/inventory_chrome.dart';
import 'package:abgui/src/ui/screens/resource_inspector.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// The columns, typed. `updatedDateTime` is an instant, so it renders relative with the exact
/// value on hover and sorts chronologically — the Swift table printed the raw ISO string and
/// sorted it as text, which happens to be right for ISO-8601 and silently wrong for anything else
/// Apple has ever emitted in that field.
List<AbColumn<Resource>> configurationColumns() => <AbColumn<Resource>>[
  AbColumn<Resource>(
    header: 'Name',
    value: (Resource row) => row.attr('name') ?? row.id,
    flex: 3,
    minWidth: 160,
  ),
  AbColumn<Resource>(
    header: 'Type',
    value: (Resource row) => row.attr('type') ?? '—',
    flex: 2,
  ),
  AbColumn<Resource>(
    header: 'Updated',
    value: (Resource row) => row.attr('updatedDateTime') ?? '—',
    type: AbColumnType.date,
    width: 170,
  ),
];

class ConfigurationsScreen extends ConsumerStatefulWidget {
  const ConfigurationsScreen({super.key});

  @override
  ConsumerState<ConfigurationsScreen> createState() =>
      _ConfigurationsScreenState();
}

class _ConfigurationsScreenState extends ConsumerState<ConfigurationsScreen> {
  static const InventoryPane _pane = InventoryPane.configurations;

  final TextEditingController _search = TextEditingController();
  final GlobalKey<AbTableState<Resource>> _table =
      GlobalKey<AbTableState<Resource>>();

  String _filter = '';

  /// The selected row's ID, not the row.
  ///
  /// Holding the `Resource` was fine while every control was a read. It is not fine now: a write
  /// re-reads the list, and a held object would then be a snapshot of what the tenant said
  /// BEFORE the write — so Delete would name, and confirm against, a version of the row that no
  /// longer exists. Resolving from the live rows on every build means the destructive controls
  /// can only ever act on what Apple Business currently reports, and a row that has gone away
  /// takes its own controls with it.
  String? _selectedId;

  CancelToken? _inFlight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Only if this pane has never read cleanly. Unlike the live inventories, the dashboard's
      // opening pass fills this cache too, and re-reading it on arrival would spend an Apple call
      // to redraw rows that are already correct.
      if (ref.read(paneStatusProvider(_pane)).hasLoaded) return;
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    _inFlight?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _inFlight?.cancel();
    final cancel = CancelToken();
    _inFlight = cancel;
    await ref.read(inventoryProvider.notifier).load(_pane, cancel: cancel);
    if (identical(_inFlight, cancel)) _inFlight = null;
  }

  void _inspect(Resource row) => unawaited(
    showResourceInspector(
      context,
      title: 'Configuration',
      symbol: 'doc.text',
      resource: row,
    ),
  );

  /// The selected row as the list currently reports it, or null.
  Resource? _selected(List<Resource> rows) {
    final String? id = _selectedId;
    if (id == null) return null;
    for (final Resource row in rows) {
      if (row.id == id) return row;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final List<Resource> rows = ref.watch(paneResourcesProvider(_pane));
    final PaneStatus status = ref.watch(paneStatusProvider(_pane));
    final AbDensity density = ref.watch(
      settingsProvider.select((Settings settings) => settings.density),
    );
    final List<AbColumn<Resource>> columns = configurationColumns();
    final Resource? selected = _selected(rows);
    final String? writeBlocked = configWriteBlocker(
      ref.watch(workspaceProvider),
    );

    return InventoryScreenFrame(
      title: 'Configurations',
      symbol: 'doc.text',
      status: inventoryStatusLine(rows.length, status),
      toolbar: <Widget>[
        InventorySearchField(
          controller: _search,
          onChanged: (String value) => setState(() => _filter = value),
        ),
        ToolbarButton(
          icon: abIcon('eye'),
          label: 'Details',
          tooltip:
              'Open the selected configuration and every attribute Apple '
              'Business returned for it.',
          onPressed: selected == null ? null : () => _inspect(selected),
        ),
        ToolbarButton(
          // The DOCUMENT, as opposed to Details' attribute bag: `abctl get configuration <id>
          // --profile` prints the `.mobileconfig` itself, and the payload keys inside it are the
          // only place the actual settings live. Apple's list endpoint never returns them, so
          // without this button the profile's contents are unreadable from the app.
          icon: abIcon('doc.text'),
          label: 'Profile',
          tooltip:
              'Fetch and show the raw .mobileconfig for the selected '
              'configuration, exactly as abctl prints it. A read — it changes nothing.',
          onPressed: selected == null
              ? null
              : () => unawaited(ProfileDialog.show(context, config: selected)),
        ),
        ToolbarButton(
          icon: abIcon('plus'),
          label: 'New',
          weight: AbToolbarWeight.titled,
          tooltip:
              writeBlocked ??
              'Write a .mobileconfig and POST it to Apple Business as a new '
                  'configuration. Checked before anything is sent.',
          onPressed: writeBlocked != null
              ? null
              : () => unawaited(_openEditor()),
        ),
        ToolbarButton(
          icon: abIcon('pencil'),
          label: 'Edit',
          tooltip:
              writeBlocked ??
              'Load the selected profile, edit it, and replace it in Apple '
                  'Business — the live version is archived first.',
          onPressed: selected == null || writeBlocked != null
              ? null
              : () => unawaited(_openEditor(existing: selected)),
        ),
        ToolbarButton(
          icon: abIcon('trash'),
          label: 'Delete',
          weight: AbToolbarWeight.titled,
          tooltip:
              writeBlocked ??
              'Delete the selected configuration from Apple Business. abctl '
                  'archives the live profile first; that copy is the only one that survives.',
          onPressed: selected == null || writeBlocked != null
              ? null
              : () => unawaited(_confirmDelete(selected)),
        ),
        CsvExportButton(
          fileName: 'abgui-configurations-export.csv',
          enabled: rows.isNotEmpty,
          document: () => csvForColumns<Resource>(
            columns: columns,
            rows: _table.currentState?.displayedRows ?? const <Resource>[],
          ),
        ),
        ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Refresh',
          tooltip: 'Re-fetch the configuration list from Apple Business.',
          onPressed: () => unawaited(_load()),
        ),
      ],
      banner: writeBlocked != null
          ? NoticeBanner(
              icon: abIcon('folder.badge.questionmark'),
              tone: AbSeverity.danger,
              text: 'No workspace — writing is unavailable',
              detail: writeBlocked,
            )
          : NoticeBanner(
              icon: abIcon('lock.open'),
              text: 'Writes Apple Business',
              detail:
                  'New, Edit and Delete change a live tenant. Each is checked before it runs, '
                  'archived where abctl archives, and reported from abctl\'s own outcome — '
                  'including whether the gitops/ tree was updated with it.',
            ),
      child: AbTable<Resource>(
        key: _table,
        rows: rows,
        columns: columns,
        rowId: (Resource row) => row.id,
        filter: _filter,
        density: density,
        selectionMode: AbSelectionMode.single,
        onSelectionChanged: (List<Resource> selected) => setState(
          () => _selectedId = selected.length == 1 ? selected.single.id : null,
        ),
        // Double-click opens the read-only inspector, exactly as it did before the write verbs
        // landed. A destructive or mutating action must never be the thing an accidental double
        // click reaches.
        onActivate: _inspect,
        isLoading: status.isLoading,
        error: status.error,
        emptyTitle: 'No configurations',
        emptyMessage:
            'This organization has no configuration profiles in Apple Business.',
        emptyIcon: abIcon('doc.text'),
        errorAction: ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Retry',
          tooltip: 'Run the read again.',
          weight: AbToolbarWeight.titled,
          onPressed: () => unawaited(_load()),
        ),
        semanticsLabel: 'Configurations',
        reportsStatus: true,
      ),
    );
  }

  /// Open the editor. The dialog re-reads the pane itself after a write, so there is nothing to
  /// refresh here — a second load would spend an Apple call to fetch what was just fetched.
  Future<void> _openEditor({Resource? existing}) =>
      ConfigEditorDialog.show(context, existing: existing);

  Future<void> _confirmDelete(Resource config) =>
      ConfigDeleteDialog.show(context, config: config);
}
