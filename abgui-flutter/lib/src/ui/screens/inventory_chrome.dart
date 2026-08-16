// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The furniture every inventory screen wears: the header/banner/body frame, the search field,
/// the small segmented pickers, and Export CSV.
///
/// It lives beside the screens rather than in `ui/widgets/` because none of it is general — each
/// piece encodes a decision that only makes sense for a read-only inventory pane, and the CSV
/// export in particular is one behaviour the Swift app got wrong in a way worth not repeating:
/// every screen recomputed "filtered then sorted" a second time to build its export, and the two
/// derivations drifted. Here the export is handed the table's OWN displayed rows, so a CSV can
/// only ever be the file version of what was on screen.
///
/// Five screens share this file, so a change to the frame lands on all of them at once — which is
/// the point. Screens importing widgets out of another SCREEN would have been the alternative,
/// and that is how a "shared" widget ends up owned by whichever screen was written first.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:abgui/src/models/csv_document.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

// The search box was inventory furniture until the membership dialog had to search a tenant's
// configurations to pick one. It now lives in `ui/widgets/search_field.dart` and is re-exported
// here, so every screen that already imported it is untouched — the same move `CopyButton` made
// out of `diagnostics_chrome.dart`, and the alternative (a dialog importing a widget out of a
// SCREEN) is exactly what this file's header warns against.
export 'package:abgui/src/ui/widgets/search_field.dart'
    show InventorySearchField;

/// The frame: a title bar with the screen's controls, an optional standing banner, and the pane
/// itself.
///
/// The title is drawn HERE rather than left to the shell, the way `.navigationTitle` left it to
/// macOS. A screen that cannot name itself is a screen that reads as a floating table when it is
/// embedded anywhere else — a dialog, a split view, a test harness — and the name is the only
/// thing that says which of eight near-identical inventories you are looking at.
class InventoryScreenFrame extends StatelessWidget {
  const InventoryScreenFrame({
    super.key,
    required this.title,
    required this.symbol,
    required this.child,
    this.status,
    this.toolbar = const <Widget>[],
    this.banner,
  });

  final String title;

  /// SF Symbol name, translated through [abIcon]. Same string the sidebar and the dashboard tile
  /// use, so one screen cannot wear three different glyphs.
  final String symbol;

  /// A quiet right-of-title line: row count, when the pane last read cleanly. Never load-bearing
  /// — it is the answer to "am I looking at fresh data?", which a table alone cannot give.
  final String? status;

  final List<Widget> toolbar;

  /// The standing fact about this pane (the read-only disclosure, a failed pass). Sits between
  /// the title bar and the content, never over it.
  final Widget? banner;

  /// The pane. Given the rest of the height, so an [AbTable] inside it is bounded and can
  /// virtualize.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return Container(
      color: ab.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: AbSpace.md),
            decoration: BoxDecoration(
              color: ab.raised,
              border: Border(bottom: BorderSide(color: ab.line)),
            ),
            child: Row(
              children: <Widget>[
                Icon(abIcon(symbol), size: 15, color: ab.dim),
                const SizedBox(width: AbSpace.sm),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                ),
                if (status != null) ...<Widget>[
                  const SizedBox(width: AbSpace.md),
                  Flexible(
                    child: Text(
                      status!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AbType.label(context),
                    ),
                  ),
                ],
                const Spacer(),
                // The toolbar SCROLLS rather than overflowing. macOS collapsed a crowded toolbar
                // into an overflow menu for us; Flutter throws a layout overflow instead, which
                // in a debug build is a red banner across the screen and in a release build is a
                // silently clipped Refresh button. `reverse: true` anchors the far end, so the
                // controls that survive a narrow window are the rightmost ones — Refresh and
                // Export, not the search field.
                Flexible(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final Widget control in toolbar) ...<Widget>[
                          const SizedBox(width: AbSpace.xs),
                          control,
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (banner != null) banner!,
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// One option in an [InventorySegmentedPicker].
@immutable
class InventorySegment<T> {
  const InventorySegment({required this.label, required this.value});

  final String label;
  final T value;
}

/// The small inline picker two screens need: the audit window and the OS-release catalog.
///
/// A row of segments rather than a dropdown because both choices are short, mutually exclusive,
/// and changed often enough that hiding them behind a menu costs a click every time — and because
/// the CURRENT choice has to be readable without interacting, since it silently scopes everything
/// in the table below it.
class InventorySegmentedPicker<T> extends StatelessWidget {
  const InventorySegmentedPicker({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    required this.tooltip,
    required this.label,
  });

  final List<InventorySegment<T>> segments;
  final T value;
  final ValueChanged<T> onChanged;

  /// What CHANGING this does, in consequence terms ("Re-read the audit trail over…") — the same
  /// contract [ToolbarButton] holds its tooltips to.
  final String tooltip;

  /// What the group IS, for a screen reader ('Audit window', 'Catalog').
  final String label;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: label,
        container: true,
        child: Container(
          decoration: BoxDecoration(
            color: ab.surface,
            border: Border.all(color: ab.line),
            borderRadius: BorderRadius.circular(AbSpace.radius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final InventorySegment<T> segment in segments)
                _Segment<T>(
                  segment: segment,
                  selected: segment.value == value,
                  onTap: () => onChanged(segment.value),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.segment,
    required this.selected,
    required this.onTap,
  });

  final InventorySegment<T> segment;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return Semantics(
      button: true,
      selected: selected,
      label: segment.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AbSpace.sm,
              vertical: 4,
            ),
            // Selection is a FILL plus weight, not a tint: on this palette a colour-only
            // difference between two adjacent labels is indistinguishable from a hover state.
            color: selected ? ab.sunken : Colors.transparent,
            child: Text(
              segment.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? ab.accent : ab.dim,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The quiet line beside a screen's title: '412 rows · read 3m ago'.
///
/// The stamp is the point, and it is why [PaneStatus.loadedAt] survives a later failure: rows
/// left on screen after a refresh fails are still the last thing the tenant said, and a pane that
/// shows them with no indication of their age lets ten-minute-old numbers pass for live ones.
String inventoryStatusLine(int count, PaneStatus status) {
  final String rows = count == 1 ? '1 row' : '$count rows';
  final DateTime? loadedAt = status.loadedAt;
  if (loadedAt == null) return rows;
  return '$rows · read ${AbRelativeTime.short(loadedAt)}';
}

/// The CSV text for a set of table columns and the rows currently displayed.
///
/// A pure function, and public, so the encoding can be tested without a save dialog: the file
/// that reaches disk is exactly this string, and everything interesting about it (which rows,
/// which order, how a missing value is spelled) is decided here.
///
/// The em dash is the SCREENS' missing-value placeholder; abctl's own `-o csv` emits an empty
/// field there. Mapping it back to "" is what makes a CSV exported from the GUI diff cleanly
/// against one piped from the CLI — the Swift export made the same trade for the same reason.
String csvForColumns<T>({
  required List<AbColumn<T>> columns,
  required List<T> rows,
}) => csvDocument(
  headers: <String>[for (final AbColumn<T> column in columns) column.header],
  rows: <List<String>>[
    for (final T row in rows)
      <String>[
        for (final AbColumn<T> column in columns)
          if (column.value(row) == '—') '' else column.value(row),
      ],
  ],
);

/// Export the rows on screen to a CSV file.
///
/// [document] is called BEFORE the save dialog opens, not after the user picks a path. A refresh
/// landing while the dialog is up would otherwise change the file's contents between the moment
/// the user decided to export and the moment they confirmed — the export names what was on
/// screen, so it has to be snapshotted at the press.
class CsvExportButton extends StatelessWidget {
  const CsvExportButton({
    super.key,
    required this.fileName,
    required this.document,
    required this.enabled,
    this.tooltip =
        'Save the rows currently shown (after search and sort) as a CSV file.',
  });

  /// The suggested name in the save dialog, e.g. `abgui-devices-export.csv`.
  final String fileName;

  final String Function() document;

  /// False when there is nothing on screen to export. A disabled control still says the feature
  /// exists and why it is unavailable; a hidden one says nothing at all.
  final bool enabled;

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return ToolbarButton(
      icon: abIcon('square.and.arrow.up'),
      label: 'Export CSV',
      tooltip: tooltip,
      onPressed: enabled ? () => unawaited(_save(context)) : null,
    );
  }

  Future<void> _save(BuildContext context) async {
    final Uint8List bytes = Uint8List.fromList(utf8.encode(document()));
    try {
      final FileSaveLocation? location = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(
            label: 'CSV',
            extensions: <String>['csv'],
            // Named for all three desktops: Linux matches on MIME, macOS on UTI, Windows on the
            // extension. Giving only the extension makes the filter silently match nothing in a
            // GTK save dialog.
            mimeTypes: <String>['text/csv'],
            uniformTypeIdentifiers: <String>[
              'public.comma-separated-values-text',
            ],
          ),
        ],
      );
      // Null is the user pressing Cancel, which is not a failure and must not raise anything.
      if (location == null) return;
      await XFile.fromData(bytes, mimeType: 'text/csv').saveTo(location.path);
    } catch (error) {
      // A save dialog is a platform channel and a write is a file system: a read-only volume, a
      // revoked folder permission, a headless session with no portal. None of that may reach the
      // error zone as a red screen over a table the user was reading.
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Couldn\'t save the CSV'),
          content: Text('$error'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}
