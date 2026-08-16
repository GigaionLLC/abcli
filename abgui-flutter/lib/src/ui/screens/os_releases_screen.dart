// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Apple's published software-release catalog (GDMF).
///
/// The one screen here that is not a tenant read: it needs no credentials, touches no
/// organization, and is availability data rather than a statement about any device — which is
/// what the banner says, in the Swift caption's own words, because an admin reading "26.1 posted"
/// beside their fleet naturally reads it as "26.1 is available to my fleet".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/os_release.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/ui/screens/inventory_chrome.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// The Swift column set, typed.
///
/// Two of these are corrections rather than translations. `Version` is [AbColumnType.mono], so it
/// sorts with digit runs compared numerically — SwiftUI's `TableColumn(value:)` sorted this
/// column as text, which puts `10.2` above `9.1` in a list whose entire purpose is telling you
/// which release is newer. `Posted` and `Expires` are [AbColumnType.date], so they read as
/// "3d ago" / "in 21d" with the exact instant on hover and sort chronologically; the expiry
/// column is also where the model's `expired` flag becomes visible without a second column
/// claiming it.
List<AbColumn<OSRelease>> osReleaseColumns() => <AbColumn<OSRelease>>[
  AbColumn<OSRelease>(
    header: 'Platform',
    value: (OSRelease row) => row.platform,
    width: 130,
  ),
  AbColumn<OSRelease>(
    header: 'Version',
    value: (OSRelease row) => row.productVersion,
    type: AbColumnType.mono,
    width: 120,
  ),
  AbColumn<OSRelease>(
    header: 'Build',
    value: (OSRelease row) => row.build,
    type: AbColumnType.mono,
    width: 120,
  ),
  AbColumn<OSRelease>(
    header: 'Catalog',
    value: (OSRelease row) => row.catalog.toUpperCase(),
    type: AbColumnType.badge,
    width: 120,
    // Neutral: `managed`, `public` and `rsr` are three kinds of feed, not three degrees of
    // health, and colouring them would invent a hierarchy Apple does not publish.
    severity: (OSRelease _) => AbSeverity.neutral,
  ),
  AbColumn<OSRelease>(
    header: 'Posted',
    value: (OSRelease row) => row.postingDate,
    type: AbColumnType.date,
    width: 150,
  ),
  AbColumn<OSRelease>(
    header: 'Expires',
    value: (OSRelease row) => row.expirationDate ?? '—',
    type: AbColumnType.date,
    width: 150,
  ),
  AbColumn<OSRelease>(
    header: 'Devices',
    value: (OSRelease row) => '${row.supportedDevices?.length ?? 0}',
    type: AbColumnType.number,
    width: 100,
  ),
];

/// The catalogs the picker offers. `all` is not a catalog Apple emits — it is the absence of the
/// filter, and it is spelled here so the picker has a value to sit on.
const String _allCatalogs = 'all';

class OsReleasesScreen extends ConsumerStatefulWidget {
  const OsReleasesScreen({super.key});

  @override
  ConsumerState<OsReleasesScreen> createState() => _OsReleasesScreenState();
}

class _OsReleasesScreenState extends ConsumerState<OsReleasesScreen> {
  static const InventoryPane _pane = InventoryPane.osReleases;

  final TextEditingController _search = TextEditingController();
  final GlobalKey<AbTableState<OSRelease>> _table =
      GlobalKey<AbTableState<OSRelease>>();

  String _filter = '';
  String _catalog = _allCatalogs;
  CancelToken? _inFlight;

  // The memo behind [_visibleRows]. Recomputing the filter on every build would re-scan the feed
  // each time a keystroke, a hover or a sort click rebuilt this widget — and worse, it would hand
  // [AbTable] a NEW list object every build, which is exactly the input its own cached derivation
  // treats as "the data changed" and re-sorts for.
  List<OSRelease>? _memoSource;
  String? _memoCatalog;
  String? _memoFilter;
  List<OSRelease> _memoRows = const <OSRelease>[];
  int _memoInCatalog = 0;

  @override
  void initState() {
    super.initState();
    // Unconditionally, unlike the tenant lists: this feed costs no Apple Business call and no
    // rate-limit budget, and it is published on Apple's schedule rather than the operator's.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
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

  /// The rows on screen: the feed narrowed by the catalog picker, then by the search text.
  ///
  /// **Why this screen filters instead of handing the text to [AbTable].** The search reaches
  /// `supportedDevices`, which the table has no column for — it shows the COUNT — and the table
  /// can only match what it can render. Passing the filter down would therefore drop precisely
  /// the rows a device-model search exists to find ("which releases still support iPhone14,3?"),
  /// silently and with no way for the user to tell. The cost is the in-cell match highlight,
  /// which is the smaller loss; the empty state below restates what the filter hid, so the
  /// "why is this pane blank?" question is still answered.
  List<OSRelease> _visibleRows(List<OSRelease> source) {
    if (identical(source, _memoSource) &&
        _catalog == _memoCatalog &&
        _filter == _memoFilter) {
      return _memoRows;
    }
    final List<OSRelease> inCatalog = _catalog == _allCatalogs
        ? source
        : <OSRelease>[
            for (final OSRelease row in source)
              if (row.catalog == _catalog) row,
          ];
    final String needle = _filter.trim().toLowerCase();
    final List<OSRelease> rows = needle.isEmpty
        ? inCatalog
        : <OSRelease>[
            for (final OSRelease row in inCatalog)
              if (_matches(row, needle)) row,
          ];
    _memoSource = source;
    _memoCatalog = _catalog;
    _memoFilter = _filter;
    _memoInCatalog = inCatalog.length;
    _memoRows = rows;
    return rows;
  }

  /// The Swift predicate, field for field: platform, version, build, or any supported device.
  static bool _matches(OSRelease row, String needle) {
    if (row.platform.toLowerCase().contains(needle)) return true;
    if (row.productVersion.toLowerCase().contains(needle)) return true;
    if (row.build.toLowerCase().contains(needle)) return true;
    for (final String device in row.supportedDevices ?? const <String>[]) {
      if (device.toLowerCase().contains(needle)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final List<OSRelease> source = ref.watch(
      inventoryProvider.select((Inventory inventory) => inventory.osReleases),
    );
    final PaneStatus status = ref.watch(paneStatusProvider(_pane));
    final AbDensity density = ref.watch(
      settingsProvider.select((Settings settings) => settings.density),
    );
    final List<AbColumn<OSRelease>> columns = osReleaseColumns();
    final List<OSRelease> rows = _visibleRows(source);

    return InventoryScreenFrame(
      title: 'OS Releases',
      symbol: 'apple.logo',
      status: inventoryStatusLine(rows.length, status),
      toolbar: <Widget>[
        InventorySearchField(
          controller: _search,
          hint: 'Platform, version, build, or device',
          width: 250,
          onChanged: (String value) => setState(() => _filter = value),
        ),
        InventorySegmentedPicker<String>(
          label: 'Catalog',
          tooltip:
              'Show one of Apple\'s release feeds: managed updates, public '
              'releases, or Rapid Security Responses.',
          value: _catalog,
          onChanged: (String value) => setState(() => _catalog = value),
          segments: const <InventorySegment<String>>[
            InventorySegment<String>(label: 'All', value: _allCatalogs),
            InventorySegment<String>(label: 'Managed', value: 'managed'),
            InventorySegment<String>(label: 'Public', value: 'public'),
            InventorySegment<String>(label: 'Security', value: 'rsr'),
          ],
        ),
        CsvExportButton(
          fileName: 'abgui-os-releases-export.csv',
          enabled: rows.isNotEmpty,
          document: () => csvForColumns<OSRelease>(
            columns: columns,
            rows: _table.currentState?.displayedRows ?? const <OSRelease>[],
          ),
        ),
        ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Refresh',
          tooltip: 'Re-fetch the Apple software-release feed (GDMF).',
          onPressed: () => unawaited(_load()),
        ),
      ],
      banner: NoticeBanner(
        icon: abIcon('info.circle'),
        text: 'Availability, not eligibility',
        detail:
            'Apple\'s software-release catalog. This is availability data, not '
            'proof that an update is eligible, scheduled, or installed.',
      ),
      child: AbTable<OSRelease>(
        key: _table,
        rows: rows,
        columns: columns,
        rowId: (OSRelease row) => row.id,
        density: density,
        // Nothing to act on: a release is not a tenant object, so there is no detail to open and
        // no selection to carry anywhere.
        selectionMode: AbSelectionMode.none,
        isLoading: status.isLoading,
        error: status.error,
        emptyTitle: _emptyTitle(source),
        emptyMessage: _emptyMessage(source),
        emptyIcon: abIcon('apple.logo'),
        errorAction: ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Retry',
          tooltip: 'Run the read again.',
          weight: AbToolbarWeight.titled,
          onPressed: () => unawaited(_load()),
        ),
        semanticsLabel: 'OS releases',
        reportsStatus: true,
      ),
    );
  }

  /// The three ways this table can be empty, kept apart.
  ///
  /// [AbTable] separates "nothing here" from "your search hid everything" on its own, but only
  /// for the filter it applies itself — and this screen applies its own (see [_visibleRows]). So
  /// the distinction is restated here rather than lost: an empty pane that does not say which
  /// case it is in is the exact ambiguity `EmptyState` was written about.
  String _emptyTitle(List<OSRelease> source) {
    if (source.isEmpty) return 'No releases';
    if (_memoInCatalog == 0) return 'Nothing in this catalog';
    return 'No matches';
  }

  String? _emptyMessage(List<OSRelease> source) {
    if (source.isEmpty) {
      return 'Apple\'s release feed returned nothing. Refresh to ask again.';
    }
    if (_memoInCatalog == 0) {
      final String count = source.length == 1
          ? '1 release'
          : '${source.length} releases';
      return '$count in the feed, none of them in this catalog.';
    }
    final String count = _memoInCatalog == 1
        ? '1 release is'
        : '$_memoInCatalog releases are';
    return '$count hidden by the filter "$_filter".';
  }
}
