// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The blueprint list.
///
/// The Swift `BlueprintsView` opened a typed sheet that spent an extra `abctl get blueprint`
/// to resolve the six member collections by name. That verb IS a read and is on the client
/// (`blueprintDetail`), but it is a screen with its own load, its own failure and its own
/// cancellation — a dialogs-layer job, not a list-screen one. Until it exists, Details opens the
/// same attribute inspector every other inventory uses, which costs no call and cannot fail.
///
/// **Membership is the one write reachable from here**, and none of it happens on this screen:
/// the toolbar button opens `MembershipDialog`, which owns the choice, the confirmation, the argv
/// preview and the outcome. What this file contributes to that write is a selected blueprint and
/// a disclosure — a list screen that could itself emit an `attach` would be a list screen able to
/// change a tenant by a mis-wired callback.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/ui/dialogs/membership_dialog.dart';
import 'package:abgui/src/ui/screens/inventory_chrome.dart';
import 'package:abgui/src/ui/screens/resource_inspector.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// Name, status, id — the Swift column set, typed.
///
/// The status pill carries NO severity, for the reason spelled out in `read_only_screen.dart`:
/// Apple's status vocabulary is open, and tinting a word we do not understand would be abgui
/// asserting something about the tenant that abgui cannot know.
List<AbColumn<Resource>> blueprintColumns() => <AbColumn<Resource>>[
  AbColumn<Resource>(
    header: 'Name',
    value: (Resource row) => row.attr('name') ?? row.id,
    flex: 2,
    minWidth: 140,
  ),
  AbColumn<Resource>(
    header: 'Status',
    value: (Resource row) => row.attr('status') ?? '—',
    type: AbColumnType.badge,
    width: 130,
    severity: (Resource _) => AbSeverity.neutral,
  ),
  AbColumn<Resource>(
    header: 'ID',
    value: (Resource row) => row.id,
    type: AbColumnType.mono,
    flex: 2,
  ),
];

class BlueprintsScreen extends ConsumerStatefulWidget {
  const BlueprintsScreen({super.key});

  @override
  ConsumerState<BlueprintsScreen> createState() => _BlueprintsScreenState();
}

class _BlueprintsScreenState extends ConsumerState<BlueprintsScreen> {
  static const InventoryPane _pane = InventoryPane.blueprints;

  final TextEditingController _search = TextEditingController();
  final GlobalKey<AbTableState<Resource>> _table =
      GlobalKey<AbTableState<Resource>>();

  String _filter = '';
  Resource? _selected;
  CancelToken? _inFlight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
      title: 'Blueprint',
      symbol: 'square.stack.3d.up',
      resource: row,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final List<Resource> rows = ref.watch(paneResourcesProvider(_pane));
    final PaneStatus status = ref.watch(paneStatusProvider(_pane));
    final AbDensity density = ref.watch(
      settingsProvider.select((Settings settings) => settings.density),
    );
    final List<AbColumn<Resource>> columns = blueprintColumns();

    return InventoryScreenFrame(
      title: 'Blueprints',
      symbol: 'square.stack.3d.up',
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
              'Open the selected blueprint and every attribute Apple Business '
              'returned for it.',
          onPressed: _selected == null ? null : () => _inspect(_selected!),
        ),
        ToolbarButton(
          icon: abIcon('link'),
          label: 'Membership',
          // Titled, not compact: this is the control whose consequence must not be misread, and
          // the tooltip names all three verbs so nobody has to open the dialog to find out
          // whether it writes the tenant.
          weight: AbToolbarWeight.titled,
          tooltip:
              'Attach or detach a configuration on the selected blueprint '
              '(both change Apple Business), or adopt one — mark a config that '
              'is already attached as git-backed so the reconcile stops '
              'proposing to detach it.',
          onPressed: _selected == null
              ? null
              : () => unawaited(
                  MembershipDialog.show(context, blueprint: _selected!),
                ),
        ),
        CsvExportButton(
          fileName: 'abgui-blueprints-export.csv',
          enabled: rows.isNotEmpty,
          document: () => csvForColumns<Resource>(
            columns: columns,
            rows: _table.currentState?.displayedRows ?? const <Resource>[],
          ),
        ),
        ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Refresh',
          tooltip: 'Re-fetch the blueprint list from Apple Business.',
          onPressed: () => unawaited(_load()),
        ),
      ],
      banner: NoticeBanner(
        icon: abIcon('lock.open'),
        text: 'Membership is gated',
        detail:
            'Blueprints as Apple Business reports them. The list itself is '
            'read-only — nothing here creates or deletes a blueprint — but '
            'Membership attaches and detaches configurations, which changes '
            'Apple Business as soon as you confirm it.',
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
          () => _selected = selected.length == 1 ? selected.single : null,
        ),
        onActivate: _inspect,
        isLoading: status.isLoading,
        error: status.error,
        emptyTitle: 'No blueprints',
        emptyMessage: 'This organization has no blueprints in Apple Business.',
        emptyIcon: abIcon('square.stack.3d.up'),
        errorAction: ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Retry',
          tooltip: 'Run the read again.',
          weight: AbToolbarWeight.titled,
          onPressed: () => unawaited(_load()),
        ),
        semanticsLabel: 'Blueprints',
        reportsStatus: true,
      ),
    );
  }
}
