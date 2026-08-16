// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:abgui/src/ui/widgets/ab_table_column.dart';

/// A row that is just its cell text: these tests are about the ORDERING a column type implies,
/// not about rendering.
class _Cell {
  const _Cell(this.text);

  final String text;
}

AbColumn<_Cell> _column(AbColumnType type) =>
    AbColumn<_Cell>(header: 'C', value: (_Cell c) => c.text, type: type);

List<String> _sorted(AbColumnType type, List<String> input) {
  final column = _column(type);
  final rows = <_Cell>[for (final String t in input) _Cell(t)];
  final order = List<int>.generate(rows.length, (int i) => i);
  order.sort((int a, int b) {
    final result = column.compareRows(rows[a], rows[b]);
    return result != 0 ? result : a - b;
  });
  return <String>[for (final int i in order) rows[i].text];
}

void main() {
  group('AbNaturalOrder', () {
    test('compares digit runs by value, not by spelling', () {
      expect(AbNaturalOrder.compare('9.1', '10.2'), lessThan(0));
      expect(AbNaturalOrder.compare('iPhone 9', 'iPhone 10'), lessThan(0));
      expect(AbNaturalOrder.compare('14.7.1', '14.7'), greaterThan(0));
    });

    test('is case-insensitive, but never calls two spellings equal', () {
      expect(AbNaturalOrder.compare('iPad', 'IPAD'), isNot(0));
      expect(AbNaturalOrder.compare('apple', 'Banana'), lessThan(0));
      expect(AbNaturalOrder.compare('same', 'same'), 0);
    });

    test('handles digit runs too long for an int', () {
      // Apple resource ids run to dozens of digits; parsing them would throw or silently
      // saturate, so the comparison is done on the digits themselves.
      final long = '1${'0' * 40}';
      final longer = '2${'0' * 40}';
      expect(AbNaturalOrder.compare(long, longer), lessThan(0));
      expect(AbNaturalOrder.compare(longer, long), greaterThan(0));
    });

    test('orders leading zeros consistently rather than calling them equal', () {
      // "007" and "7" are equal in VALUE, so the digit comparison alone would return 0 and hand
      // the decision to the index tiebreak — meaning two rows could swap places depending only
      // on what order they arrived in. The rule (fewer leading zeros first) is arbitrary; that
      // there IS a rule is not.
      expect(AbNaturalOrder.compare('7', '007'), lessThan(0));
      expect(AbNaturalOrder.compare('007', '7'), greaterThan(0));
      expect(AbNaturalOrder.compare('007', '007'), 0);
    });

    test('a prefix sorts before the string that extends it', () {
      expect(AbNaturalOrder.compare('mac', 'macbook'), lessThan(0));
      expect(AbNaturalOrder.compare('macbook', 'mac'), greaterThan(0));
    });
  });

  group('column ordering by type', () {
    test('number sorts numerically and parks unparseable values last', () {
      expect(
        _sorted(AbColumnType.number, <String>['1000', '9', '—', '42']),
        <String>['9', '42', '1000', '—'],
      );
    });

    test('date sorts chronologically, not by the shape of the string', () {
      expect(
        _sorted(AbColumnType.date, <String>[
          '2026-01-05T00:00:00Z',
          '2025-12-31T23:00:00Z',
          'never',
        ]),
        <String>['2025-12-31T23:00:00Z', '2026-01-05T00:00:00Z', 'never'],
      );
    });

    test('mono uses natural order', () {
      expect(
        _sorted(AbColumnType.mono, <String>['10.2', '9.1', '10.10']),
        <String>['9.1', '10.2', '10.10'],
      );
    });

    test('a custom comparator wins over the type', () {
      // The case this exists for: a status column that must sort by seriousness, not spelling.
      const List<String> rank = <String>['failed', 'pending', 'ok'];
      final column = AbColumn<_Cell>(
        header: 'Status',
        value: (_Cell c) => c.text,
        compare: (_Cell a, _Cell b) =>
            rank.indexOf(a.text).compareTo(rank.indexOf(b.text)),
      );
      expect(
        column.compareRows(const _Cell('failed'), const _Cell('ok')),
        lessThan(0),
      );
    });
  });

  group('AbRelativeTime', () {
    final DateTime now = DateTime(2026, 8, 15, 12);

    test('reads relative inside a week', () {
      expect(
        AbRelativeTime.short(
          now.subtract(const Duration(seconds: 5)),
          now: now,
        ),
        'just now',
      );
      expect(
        AbRelativeTime.short(
          now.subtract(const Duration(minutes: 4)),
          now: now,
        ),
        '4m ago',
      );
      expect(
        AbRelativeTime.short(now.subtract(const Duration(hours: 7)), now: now),
        '7h ago',
      );
      expect(
        AbRelativeTime.short(now.subtract(const Duration(days: 3)), now: now),
        '3d ago',
      );
    });

    test('falls back to a calendar date past a week', () {
      // "63d ago" is not a date anyone can place.
      expect(
        AbRelativeTime.short(now.subtract(const Duration(days: 63)), now: now),
        '2026-06-13',
      );
    });

    test('says so when a timestamp is in the future', () {
      // Expiry dates and clock-skewed machines both land here; "in 2d" is honest where
      // "2d ago" would be a lie about the same value.
      expect(
        AbRelativeTime.short(now.add(const Duration(days: 2)), now: now),
        'in 2d',
      );
      expect(
        AbRelativeTime.short(now.add(const Duration(seconds: 3)), now: now),
        'in a moment',
      );
    });

    test(
      'the absolute form is ISO-shaped, so it matches what abctl prints',
      () {
        expect(
          AbRelativeTime.absolute(DateTime(2026, 7, 4, 9, 5, 3)),
          '2026-07-04 09:05:03',
        );
        expect(
          AbRelativeTime.absolute(DateTime(2026, 7, 4), includeTime: false),
          '2026-07-04',
        );
      },
    );
  });
}
