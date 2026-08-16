// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// One screen for all eight live Apple Business inventories, driven by [ReadOnlyKind] — the same
/// shape the Swift `ReadOnlyListView` had, and for the same reason: the eight screens differ only
/// in their columns, their note and which verb fills them, so eight files would be eight copies of
/// one search box, one export and one refresh, drifting apart one fix at a time.
///
/// **Read-only with ONE disclosed exception, on ONE kind.** Devices carries the gated Assign to
/// MDM… write — the Business API's only device write — exactly as the Swift original did, and that
/// screen is badged "Read-only · assignment gated" so the exception is stated rather than
/// discovered. Every other kind here has no write verb at all.
///
/// The exception is why [ReadOnlyKind.devices] is also the only kind whose table allows a MULTIPLE
/// selection: assignment is a bulk verb (serials are positional arguments), and the selection IS
/// its argument list. The other seven stay single-select, because a multi-select that leads
/// nowhere only invites the question "now what?".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/read_only_kind.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/ui/dialogs/assign_dialog.dart';
import 'package:abgui/src/ui/screens/inventory_chrome.dart';
import 'package:abgui/src/ui/screens/resource_inspector.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

class ReadOnlyScreen extends ConsumerStatefulWidget {
  const ReadOnlyScreen({super.key, required this.kind});

  final ReadOnlyKind kind;

  @override
  ConsumerState<ReadOnlyScreen> createState() => _ReadOnlyScreenState();
}

class _ReadOnlyScreenState extends ConsumerState<ReadOnlyScreen> {
  final TextEditingController _search = TextEditingController();

  /// One table key PER KIND, created on first use.
  ///
  /// Two jobs. The key is how Export CSV reaches [AbTableState.displayedRows] — deriving
  /// "filtered then sorted" a second time in this screen is how the Swift export came to
  /// disagree with the table it claimed to copy. And keying it on the KIND means switching
  /// resources builds a different table rather than reusing one: the previous kind's sort column
  /// and selection go with it, which is what the Swift view's `onChange(of: kind)` reset by hand.
  final Map<ReadOnlyKind, GlobalKey<AbTableState<Resource>>> _tables =
      <ReadOnlyKind, GlobalKey<AbTableState<Resource>>>{};

  String _filter = '';

  /// The single-row controls' subject: null unless EXACTLY one row is selected. Details opens one
  /// resource, so two selected rows is not a smaller version of its question — it is a different
  /// one, and the button goes inert rather than picking a row on the user's behalf.
  Resource? _selected;

  /// Every selected row, which on Devices is the assign verb's argument list. Kept beside
  /// [_selected] rather than derived from it: the two controls answer to different arities, and
  /// collapsing them is how a bulk action ends up acting on one row.
  List<Resource> _selection = const <Resource>[];

  /// This screen's own in-flight read. Cancelled when the screen goes away or starts another
  /// one, so a 60-second device fetch does not outlive the pane that asked for it — the store's
  /// generation already ignores a superseded result, but only a cancel stops the process.
  CancelToken? _inFlight;

  @override
  void initState() {
    super.initState();
    // Post-frame, not inline: `load` publishes a spinner synchronously, and moving a provider
    // during the build that mounted this widget is a framework error.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void didUpdateWidget(ReadOnlyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind == widget.kind) return;
    // The shell may reuse this instance across a sidebar switch. The previous kind's search text
    // and selection describe rows that do not exist here, so they go with it.
    _search.clear();
    _filter = '';
    _selected = null;
    _selection = const <Resource>[];
    unawaited(_load());
  }

  @override
  void dispose() {
    _inFlight?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final InventoryPane? pane = InventoryPane.forReadOnly(widget.kind);
    if (pane == null) return;
    _inFlight?.cancel();
    final cancel = CancelToken();
    _inFlight = cancel;
    await ref.read(inventoryProvider.notifier).load(pane, cancel: cancel);
    if (identical(_inFlight, cancel)) _inFlight = null;
  }

  void _setAuditSince(String since) {
    ref.read(inventoryProvider.notifier).setAuditSince(since);
    // The store deliberately does NOT refetch on a window change — it cannot know whether the
    // control that changed it is a text field mid-keystroke. This one is four fixed buttons, so
    // spending the call here is exactly what the user asked for.
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final ReadOnlyKind kind = widget.kind;
    final InventoryPane? pane = InventoryPane.forReadOnly(kind);
    if (pane == null) {
      // [ReadOnlyKind.unknown] — a value restored from settings that this build does not know.
      // It is not a screen, and it must not be able to crash one.
      return const InventoryScreenFrame(
        title: 'Unknown section',
        symbol: 'questionmark.circle',
        child: EmptyState(
          icon: Icons.help_outline,
          title: 'Unknown section',
          message: 'This build has no screen for the selected resource.',
        ),
      );
    }

    final List<Resource> rows = ref.watch(paneResourcesProvider(pane));
    final PaneStatus status = ref.watch(paneStatusProvider(pane));
    final AbDensity density = ref.watch(
      settingsProvider.select((Settings settings) => settings.density),
    );
    final List<AbColumn<Resource>> columns = readOnlyColumns(kind);
    final GlobalKey<AbTableState<Resource>> tableKey = _tables.putIfAbsent(
      kind,
      GlobalKey<AbTableState<Resource>>.new,
    );

    return InventoryScreenFrame(
      title: kind.title,
      symbol: kind.symbol,
      status: inventoryStatusLine(rows.length, status),
      toolbar: <Widget>[
        InventorySearchField(
          controller: _search,
          onChanged: (String value) => setState(() => _filter = value),
        ),
        if (kind == ReadOnlyKind.audit)
          InventorySegmentedPicker<String>(
            label: 'Audit window',
            tooltip:
                'Re-read the audit trail over this window. A longer window is a '
                'bigger request to Apple Business.',
            value: ref.watch(
              inventoryProvider.select(
                (Inventory inventory) => inventory.auditSince,
              ),
            ),
            onChanged: _setAuditSince,
            segments: const <InventorySegment<String>>[
              InventorySegment<String>(label: '24h', value: '24h'),
              InventorySegment<String>(label: '7d', value: '7d'),
              InventorySegment<String>(label: '30d', value: '30d'),
              InventorySegment<String>(label: '90d', value: '90d'),
            ],
          ),
        ToolbarButton(
          icon: abIcon('eye'),
          label: 'Details',
          tooltip:
              'Open the selected row and every attribute Apple Business '
              'returned for it. Reads nothing further.',
          onPressed: _selected == null ? null : () => _inspect(_selected!),
        ),
        // The one write on this screen, on the one kind that has one. Titled, because a control
        // that changes which MDM server manages a fleet must not be an unlabelled glyph.
        if (kind == ReadOnlyKind.devices)
          ToolbarButton(
            icon: abIcon('arrow.left.arrow.right'),
            label: 'Assign to MDM…',
            weight: AbToolbarWeight.titled,
            tooltip:
                'Assign or unassign the selected devices on an MDM server. '
                'Gated: the dialog shows the exact command and asks before it '
                'reaches Apple Business.',
            onPressed: _selection.isEmpty ? null : () => unawaited(_assign()),
          ),
        CsvExportButton(
          fileName: 'abgui-${kind.wire}-export.csv',
          enabled: rows.isNotEmpty,
          document: () => csvForColumns<Resource>(
            columns: columns,
            rows: tableKey.currentState?.displayedRows ?? const <Resource>[],
          ),
        ),
        ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Refresh',
          tooltip: 'Re-fetch this inventory from Apple Business.',
          onPressed: () => unawaited(_load()),
        ),
      ],
      banner: NoticeBanner(
        icon: abIcon(kind == ReadOnlyKind.devices ? 'lock.open' : 'lock'),
        // The Swift badge, restored now that the verb behind it exists again. It said
        // "Read-only · assignment gated" precisely because the exception has to be visible on
        // the screen that carries it, not buried in the dialog it opens.
        text: kind == ReadOnlyKind.devices
            ? 'Read-only · assignment gated'
            : 'Read-only',
        detail: kind.note,
      ),
      child: AbTable<Resource>(
        key: tableKey,
        rows: rows,
        columns: columns,
        rowId: (Resource row) => row.id,
        filter: _filter,
        density: density,
        // Multiple on Devices ONLY, because that is the one kind with a bulk verb behind it:
        // `assign` takes the serials positionally, so the selection is literally the argument
        // list. Everywhere else a multi-select would lead nowhere.
        selectionMode: kind == ReadOnlyKind.devices
            ? AbSelectionMode.multiple
            : AbSelectionMode.single,
        onSelectionChanged: (List<Resource> selected) => setState(() {
          _selection = selected;
          _selected = selected.length == 1 ? selected.single : null;
        }),
        onActivate: _inspect,
        isLoading: status.isLoading,
        error: status.error,
        emptyTitle: 'No ${kind.title.toLowerCase()}',
        emptyMessage: 'Apple Business returned no rows for this organization.',
        emptyIcon: abIcon(kind.symbol),
        errorAction: ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Retry',
          tooltip: 'Run the read again.',
          weight: AbToolbarWeight.titled,
          onPressed: () => unawaited(_load()),
        ),
        semanticsLabel: kind.title,
        reportsStatus: true,
      ),
    );
  }

  void _inspect(Resource row) => unawaited(
    showResourceInspector(
      context,
      title: widget.kind.title,
      symbol: widget.kind.symbol,
      resource: row,
    ),
  );

  /// Open the gated assignment dialog over the rows the user picked.
  ///
  /// A re-read follows an ACCEPTED activity, and only that: the table now disagrees with the
  /// tenant, and leaving stale server assignments on screen after a write is how an operator
  /// repeats one. It is not a promise that the new value will show — Apple applies the activity
  /// asynchronously, which the dialog says in as many words — but the row the user just acted on
  /// must not be one nobody re-read.
  Future<void> _assign() async {
    final List<Resource> devices = _selection;
    if (devices.isEmpty) return;
    final bool submitted = await AssignDialog.show(context, devices: devices);
    if (!submitted || !mounted) return;
    await _load();
  }
}

/// The columns for one kind, typed.
///
/// The VALUES come from [ReadOnlyKind.columns] and are never respelled here: most of them fall
/// back (`serialNumber ?? id`), join (`firstName` + `lastName`) or flatten a nested array
/// (`roles[].role`), and a second copy of that logic in the view is exactly how the Swift table
/// and its CSV export came to disagree. What this adds is the one thing `ColumnSpec` cannot carry
/// — what the column HOLDS — which is what buys tabular figures on a serial, a numeric sort on a
/// count, a relative-with-hover rendering on a timestamp, and a pill on a status word.
///
/// Keyed on the header because that is `ColumnSpec`'s own identity. A header renamed in the model
/// falls through to the [AbColumnType.text] default: the column still renders, still sorts and
/// still exports — it just loses its face, which is a visible cosmetic regression rather than a
/// crash or a silently wrong sort.
List<AbColumn<Resource>> readOnlyColumns(ReadOnlyKind kind) =>
    <AbColumn<Resource>>[
      for (final ColumnSpec spec in kind.columns) _column(spec),
    ];

AbColumn<Resource> _column(ColumnSpec spec) => switch (spec.header) {
  // Machine data. Monospaced + tabular so a transposed digit in a serial is visible, and sorted
  // with digit runs compared numerically so `iPhone 10` follows `iPhone 9`.
  'Serial' => AbColumn<Resource>(
    header: spec.header,
    value: spec.value,
    type: AbColumnType.mono,
    width: 150,
  ),
  'ID' ||
  'Bundle ID' ||
  'Managed Apple ID' ||
  'Enrolled User' => AbColumn<Resource>(
    header: spec.header,
    value: spec.value,
    type: AbColumnType.mono,
    flex: 2,
  ),
  'Version' => AbColumn<Resource>(
    header: spec.header,
    value: spec.value,
    type: AbColumnType.mono,
    width: 120,
  ),
  // An instant: rendered relative with the exact value on hover, and sorted chronologically
  // rather than by the shape of the string. The Swift audit table printed raw ISO text.
  'Time' => AbColumn<Resource>(
    header: spec.header,
    value: spec.value,
    type: AbColumnType.date,
    width: 160,
  ),
  // A short state word, drawn as a pill — and deliberately with NO severity mapping. Apple's
  // status vocabulary is open (and differs between users, groups and devices), so colouring a
  // value we do not understand would be abgui claiming something about the tenant that abgui
  // does not know. The pill gives it shape; the word carries the meaning.
  'Status' => AbColumn<Resource>(
    header: spec.header,
    value: spec.value,
    type: AbColumnType.badge,
    width: 130,
    severity: (Resource _) => AbSeverity.neutral,
  ),
  'Name' => AbColumn<Resource>(
    header: spec.header,
    value: spec.value,
    flex: 2,
    minWidth: 120,
  ),
  'Roles' => AbColumn<Resource>(
    header: spec.header,
    value: spec.value,
    flex: 2,
  ),
  _ => AbColumn<Resource>(header: spec.header, value: spec.value),
};
