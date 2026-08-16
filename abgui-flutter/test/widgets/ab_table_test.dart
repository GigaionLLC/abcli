// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';

/// A stand-in for the resource rows the real screens show. Deliberately carries a column with
/// MANY duplicate values (status) — that is the input that exposes an unstable sort.
class _Row {
  const _Row(this.id, this.name, this.status, this.version);

  final String id;
  final String name;
  final String status;
  final String version;
}

List<_Row> _rows(int count) => <_Row>[
  for (var i = 0; i < count; i++)
    _Row(
      'r$i',
      'device-$i',
      // Two values across N rows: every comparison inside a group is a tie, so the tiebreak is
      // doing all the work and any instability shows up immediately.
      i.isEven ? 'ok' : 'drift',
      '${i % 3 + 9}.1',
    ),
];

final List<AbColumn<_Row>> _columns = <AbColumn<_Row>>[
  AbColumn<_Row>(header: 'Name', value: (_Row r) => r.name),
  AbColumn<_Row>(
    header: 'Status',
    value: (_Row r) => r.status,
    type: AbColumnType.badge,
    severity: (_Row r) => r.status == 'ok' ? AbSeverity.ok : AbSeverity.drift,
  ),
  AbColumn<_Row>(
    header: 'Version',
    value: (_Row r) => r.version,
    type: AbColumnType.mono,
  ),
];

Widget _harness(
  List<_Row> rows, {
  String filter = '',
  bool isLoading = false,
  String? error,
  bool autofocus = false,
  void Function(List<_Row>)? onSelectionChanged,
  void Function(_Row)? onActivate,
  AbSelectionMode selectionMode = AbSelectionMode.multiple,
}) {
  return MaterialApp(
    theme: abTheme(Brightness.light),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 900,
          // Bounded, as AbTable requires: an unbounded table cannot virtualize.
          height: 300,
          child: AbTable<_Row>(
            rows: rows,
            columns: _columns,
            rowId: (_Row r) => r.id,
            filter: filter,
            isLoading: isLoading,
            error: error,
            autofocus: autofocus,
            selectionMode: selectionMode,
            onSelectionChanged: onSelectionChanged,
            onActivate: onActivate,
            emptyTitle: 'No devices',
            emptyMessage: 'This organization has no devices.',
            // Wide enough that a stalled test runner cannot turn one double-click into two
            // single clicks (or the reverse). The tests are about the RULES around activation,
            // never about how fast the harness happens to be.
            doubleClickWindow: const Duration(seconds: 5),
          ),
        ),
      ),
    ),
  );
}

AbTableState<_Row> _state(WidgetTester tester) =>
    tester.state<AbTableState<_Row>>(find.byType(AbTable<_Row>));

List<String> _displayedIds(WidgetTester tester) => <String>[
  for (final _Row row in _state(tester).displayedRows) row.id,
];

Future<void> _tapHeader(WidgetTester tester, String header) async {
  await tester.tap(find.text(header.toUpperCase()));
  await tester.pump();
}

Future<void> _tapRow(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey<String>(id)));
  await tester.pump();
}

/// Every span in the tree that wears the filter-match treatment.
List<TextSpan> _highlightedSpans(WidgetTester tester) {
  final hits = <TextSpan>[];
  for (final RichText rich in tester.widgetList<RichText>(
    find.byType(RichText),
  )) {
    rich.text.visitChildren((InlineSpan span) {
      if (span is TextSpan &&
          span.style?.backgroundColor != null &&
          (span.text ?? '').isNotEmpty) {
        hits.add(span);
      }
      return true;
    });
  }
  return hits;
}

void main() {
  group('sorting', () {
    testWidgets('is stable across rebuilds when keys are duplicated', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(10)));
      await _tapHeader(tester, 'Status');

      // 'drift' sorts before 'ok'; WITHIN each group the source order must survive, because the
      // only thing separating those rows is their original index.
      const List<String> expected = <String>[
        'r1', 'r3', 'r5', 'r7', 'r9', // drift, in source order
        'r0', 'r2', 'r4', 'r6', 'r8', // ok, in source order
      ];
      expect(_displayedIds(tester), expected);

      // A refresh lands: same content, a brand-new list object (so the table genuinely
      // re-derives rather than short-circuiting on identity). Rows must not move.
      await tester.pumpWidget(_harness(_rows(10)));
      await tester.pump();
      expect(_displayedIds(tester), expected);
    });

    testWidgets('reverses the keys, not the equal-key groups', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(10)));
      await _tapHeader(tester, 'Status');
      await _tapHeader(tester, 'Status');

      expect(_state(tester).sortAscending, isFalse);
      // The GROUPS swap, but inside each group the index tiebreak still runs ascending —
      // otherwise flipping direction twice would not return you to where you started.
      expect(_displayedIds(tester), <String>[
        'r0', 'r2', 'r4', 'r6', 'r8', // ok
        'r1', 'r3', 'r5', 'r7', 'r9', // drift
      ]);

      await _tapHeader(tester, 'Status');
      expect(_displayedIds(tester), <String>[
        'r1',
        'r3',
        'r5',
        'r7',
        'r9',
        'r0',
        'r2',
        'r4',
        'r6',
        'r8',
      ]);
    });

    testWidgets('marks only the sorted column with a direction', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(4)));
      expect(find.byIcon(Icons.arrow_upward), findsNothing);

      await _tapHeader(tester, 'Name');
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      expect(find.byIcon(Icons.arrow_downward), findsNothing);

      await _tapHeader(tester, 'Name');
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    });

    testWidgets('orders a mono column by value, not by spelling', (
      WidgetTester tester,
    ) async {
      const List<_Row> rows = <_Row>[
        _Row('a', 'a', 'ok', '10.2'),
        _Row('b', 'b', 'ok', '9.1'),
        _Row('c', 'c', 'ok', '10.10'),
      ];
      await tester.pumpWidget(_harness(rows));
      await _tapHeader(tester, 'Version');
      // Lexicographically this is 10.10, 10.2, 9.1 — which is what the Swift table showed and
      // what makes an admin believe a fleet is on a newer OS than it is.
      expect(_displayedIds(tester), <String>['b', 'a', 'c']);
    });
  });

  group('selection', () {
    testWidgets('shift-click extends a range from the anchor', (
      WidgetTester tester,
    ) async {
      List<_Row> selected = const <_Row>[];
      await tester.pumpWidget(
        _harness(
          _rows(10),
          onSelectionChanged: (List<_Row> rows) => selected = rows,
        ),
      );

      await _tapRow(tester, 'r1');
      expect(_state(tester).selectedIds, <String>{'r1'});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _tapRow(tester, 'r5');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(_state(tester).selectedIds, <String>{
        'r1',
        'r2',
        'r3',
        'r4',
        'r5',
      });
      expect(
        <String>[for (final _Row r in selected) r.id],
        <String>['r1', 'r2', 'r3', 'r4', 'r5'],
      );
    });

    testWidgets('shift-click back over the anchor shrinks the range', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(10)));
      await _tapRow(tester, 'r2');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _tapRow(tester, 'r6');
      expect(_state(tester).selectedIds.length, 5);
      // Dragging the far end back must SHRINK the range. An implementation that unions each
      // shift-click leaves r5 and r6 selected here, and the user has no way to see it.
      await _tapRow(tester, 'r4');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(_state(tester).selectedIds, <String>{'r2', 'r3', 'r4'});
    });

    testWidgets('ctrl-click toggles one row without clearing the rest', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(10)));
      await _tapRow(tester, 'r0');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await _tapRow(tester, 'r4');
      expect(_state(tester).selectedIds, <String>{'r0', 'r4'});
      await _tapRow(tester, 'r4');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      // The second modified click deselects; it is NOT a double-click, so no detail opens and
      // r0 is untouched.
      expect(_state(tester).selectedIds, <String>{'r0'});
    });

    testWidgets('survives a refresh, and drops rows that vanished', (
      WidgetTester tester,
    ) async {
      List<_Row> selected = const <_Row>[];
      await tester.pumpWidget(
        _harness(
          _rows(10),
          onSelectionChanged: (List<_Row> rows) => selected = rows,
        ),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _tapRow(tester, 'r0');
      await _tapRow(tester, 'r2');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(_state(tester).selectedIds, <String>{'r0', 'r1', 'r2'});

      // Selection is held by id, so a re-fetch that rebuilds every object keeps it...
      await tester.pumpWidget(_harness(_rows(10)));
      await tester.pump();
      expect(_state(tester).selectedIds, <String>{'r0', 'r1', 'r2'});

      // ...and a re-fetch that no longer contains r2 must not leave the parent holding an id
      // for a row that is gone.
      await tester.pumpWidget(
        _harness(
          _rows(2),
          onSelectionChanged: (List<_Row> rows) => selected = rows,
        ),
      );
      await tester.pump();
      expect(_state(tester).selectedIds, <String>{'r0', 'r1'});
      expect(
        <String>[for (final _Row r in selected) r.id],
        <String>['r0', 'r1'],
      );
    });

    testWidgets('is inert when the table is not selectable', (
      WidgetTester tester,
    ) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        _harness(
          _rows(4),
          selectionMode: AbSelectionMode.none,
          onActivate: (_Row row) => opened.add(row.id),
        ),
      );
      await _tapRow(tester, 'r1');
      expect(_state(tester).selectedIds, isEmpty);

      // A display-only table still OPENS a row: not being able to select rows is not the same
      // as not being able to look at one.
      await _tapRow(tester, 'r1');
      expect(opened, <String>['r1']);
    });

    testWidgets('single-selection mode ignores the multi-select modifiers', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _harness(_rows(10), selectionMode: AbSelectionMode.single),
      );
      await _tapRow(tester, 'r1');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _tapRow(tester, 'r5');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(_state(tester).selectedIds, <String>{'r5'});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      // Select-all on a single-selection table would hand the parent a list it has no way to
      // act on, so it does nothing at all.
      expect(_state(tester).selectedIds, <String>{'r5'});
    });

    testWidgets('double-click opens the row, single click does not', (
      WidgetTester tester,
    ) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        _harness(_rows(10), onActivate: (_Row row) => opened.add(row.id)),
      );

      await _tapRow(tester, 'r2');
      expect(opened, isEmpty);
      await _tapRow(tester, 'r2');
      expect(opened, <String>['r2']);

      // Two clicks on two DIFFERENT rows are two selections, however fast they land.
      await _tapRow(tester, 'r3');
      await _tapRow(tester, 'r4');
      expect(opened, <String>['r2']);
      expect(_state(tester).selectedIds, <String>{'r4'});
    });
  });

  group('keyboard', () {
    testWidgets('arrows move, shift-arrows extend, ctrl-A selects all', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(10), autofocus: true));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_state(tester).selectedIds, <String>{'r0'});

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_state(tester).selectedIds, <String>{'r1'});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(_state(tester).selectedIds, <String>{'r1', 'r2', 'r3'});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(_state(tester).selectedIds.length, 10);
    });

    testWidgets('End jumps to the last row and scrolls it into view', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(200), autofocus: true));
      await tester.pump();

      // The last row is far below the fold and has never been built — reveal is arithmetic on
      // the fixed row extent, not a search through built children.
      expect(find.byKey(const ValueKey<String>('r199')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();

      expect(_state(tester).selectedIds, <String>{'r199'});
      expect(find.byKey(const ValueKey<String>('r199')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(_state(tester).selectedIds, <String>{'r0'});
      expect(find.byKey(const ValueKey<String>('r0')), findsOneWidget);
    });

    testWidgets('Enter activates the cursor row', (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        _harness(
          _rows(10),
          autofocus: true,
          onActivate: (_Row row) => opened.add(row.id),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(opened, <String>['r1']);
    });
  });

  group('filtering', () {
    testWidgets('keeps matching rows and highlights the matched run', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(10), filter: 'device-3'));
      await tester.pump();

      expect(_displayedIds(tester), <String>['r3']);

      final List<TextSpan> hits = _highlightedSpans(tester);
      expect(hits, isNotEmpty);
      // The highlight must land on the substring that actually matched — that is the whole
      // point of it, and a whole-cell highlight would hide WHERE the match was.
      expect(hits.first.text, 'device-3');
    });

    testWidgets('matches case-insensitively and highlights every occurrence', (
      WidgetTester tester,
    ) async {
      const List<_Row> rows = <_Row>[
        _Row('a', 'ABC-abc', 'ok', '1.0'),
        _Row('b', 'zzz', 'ok', '1.0'),
      ];
      await tester.pumpWidget(_harness(rows, filter: 'aBc'));
      await tester.pump();

      expect(_displayedIds(tester), <String>['a']);
      final List<String> texts = <String>[
        for (final TextSpan span in _highlightedSpans(tester)) span.text!,
      ];
      // Both runs in "ABC-abc", in the source's own casing — highlighting must never rewrite
      // the value it is drawing attention to.
      expect(texts, <String>['ABC', 'abc']);
    });

    testWidgets('a filter that matches a badge highlights inside the pill', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(4), filter: 'drift'));
      await tester.pump();

      expect(_displayedIds(tester), <String>['r1', 'r3']);
      expect(find.byType(AbBadge), findsNWidgets(2));
      expect(<String>[
        for (final TextSpan span in _highlightedSpans(tester)) span.text!,
      ], everyElement('drift'));
    });
  });

  group('states', () {
    testWidgets('an empty list renders the empty state, not a blank pane', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(const <_Row>[]));
      await tester.pump();

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('No devices'), findsOneWidget);
      expect(find.text('This organization has no devices.'), findsOneWidget);
      // The column header stays put so the pane still says what it WOULD show, and so the
      // layout does not jump when rows arrive.
      expect(find.text('NAME'), findsOneWidget);
    });

    testWidgets('an empty RESULT says the filter is what hid everything', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(10), filter: 'no-such-device'));
      await tester.pump();

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('No matches'), findsOneWidget);
      // Naming the count is the difference between "you have no devices" and "your search is
      // hiding all ten of them".
      expect(
        find.text('10 rows are hidden by the filter "no-such-device".'),
        findsOneWidget,
      );
    });

    testWidgets('the empty state stays on screen when the columns overflow', (
      WidgetTester tester,
    ) async {
      // 200px cannot hold three columns at their 72px floor, so the table is in its horizontal
      // scrolling mode. The explanation must still be where the user is looking.
      await tester.pumpWidget(
        MaterialApp(
          theme: abTheme(Brightness.light),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 300,
                child: AbTable<_Row>(
                  rows: const <_Row>[],
                  columns: _columns,
                  rowId: (_Row r) => r.id,
                  emptyTitle: 'No devices',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final Rect table = tester.getRect(find.byType(AbTable<_Row>));
      final double centre = tester.getCenter(find.byType(EmptyState)).dx;
      expect(centre, greaterThanOrEqualTo(table.left));
      expect(centre, lessThanOrEqualTo(table.right));
    });

    testWidgets('a first load shows a spinner, not an empty state', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(const <_Row>[], isLoading: true));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(EmptyState), findsNothing);
    });

    testWidgets('a failed first load shows the error in place of the rows', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _harness(const <_Row>[], error: 'token expired (401)'),
      );
      await tester.pump();

      expect(find.text('Couldn\'t load'), findsOneWidget);
      expect(find.text('token expired (401)'), findsOneWidget);
    });

    testWidgets('a failed REFRESH keeps the rows and says they are stale', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(6), error: 'network unreachable'));
      await tester.pump();

      // The Swift app showed an error only when the list was empty, so a stale table was
      // indistinguishable from a fresh one.
      final NoticeBanner banner = tester.widget<NoticeBanner>(
        find.byType(NoticeBanner),
      );
      expect(banner.text, 'Showing the last data that loaded');
      expect(banner.detail, 'network unreachable');
      expect(banner.tone, AbSeverity.danger);
      expect(find.byKey(const ValueKey<String>('r0')), findsOneWidget);
      expect(find.byType(EmptyState), findsNothing);
    });

    testWidgets('a refresh over existing rows does not blank the pane', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(_rows(6), isLoading: true));
      await tester.pump();

      expect(find.byKey(const ValueKey<String>('r0')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  testWidgets('virtualizes: 5,000 rows build only what fits', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_harness(_rows(5000)));
    await tester.pump();

    expect(_state(tester).displayedRows.length, 5000);
    // A 300px-tall pane cannot have built row 4,999 — if this ever fails, the table has stopped
    // virtualizing and a real tenant's device list will take seconds to open.
    expect(find.byKey(const ValueKey<String>('r4999')), findsNothing);
    expect(find.byKey(const ValueKey<String>('r0')), findsOneWidget);
  });
}
