// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/widgets/badge.dart';

/// What KIND of thing a column holds.
///
/// This enum is the whole argument for replacing SwiftUI's `Table`. `NSTableView` was handed
/// strings and could only ever render, align and sort them as strings — which is why the Swift
/// app sorted versions lexicographically ("10.2" before "9.1"), left serial numbers in a
/// proportional face where a transposed digit is invisible, and printed raw ISO timestamps
/// nobody can read at a glance. Declaring the type once here fixes alignment, face, sort order
/// and hover detail together, at the one place that actually knows the answer.
enum AbColumnType {
  /// Language: names, models, notes. Proportional face.
  text,

  /// Machine data: serials, ids, bundle ids, versions, paths. Monospaced + tabular, and sorted
  /// with digit runs compared numerically so `iPhone 10` follows `iPhone 9`.
  mono,

  /// A count or size. Monospaced, right-aligned, and sorted NUMERICALLY — the difference
  /// between "1000 < 9" and "9 < 1000".
  number,

  /// An instant. Rendered relative ("3h ago") with the absolute value on hover, and sorted
  /// chronologically rather than by the shape of the string.
  date,

  /// A short state word. Rendered as a bordered pill via [AbBadge].
  badge,
}

/// One column of an [AbTable].
///
/// [value] is a function of the row, not a key name, for the reason `ColumnSpec` already
/// documents in `models/read_only_kind.dart`: most columns are not one key — they fall back
/// (`serialNumber ?? id`), join (`firstName` + `lastName`) or flatten a nested array. Keeping
/// that in the column means the table, the CSV export and the search all read the SAME string,
/// which is precisely where the Swift table and its export drifted apart.
@immutable
class AbColumn<T> {
  const AbColumn({
    required this.header,
    required this.value,
    this.type = AbColumnType.text,
    this.width,
    this.flex = 1,
    this.minWidth = 72,
    this.sortable = true,
    this.severity,
    this.compare,
    this.align,
  }) : assert(flex > 0, 'a flex column must claim at least one share');

  /// The header text. Also the column's identity for sorting — headers are unique within a
  /// table by construction, and using them keeps a persisted sort choice human-readable.
  final String header;

  /// The display string for a row. Called for rendering, for sorting, and for filter matching,
  /// so a row can never match a search on text the user cannot see.
  final String Function(T row) value;

  final AbColumnType type;

  /// A fixed width in logical pixels. Use it for columns whose content has a known size — a
  /// serial, a status pill — so they do not breathe as the window resizes.
  final double? width;

  /// Share of the leftover width, when [width] is null.
  final int flex;

  /// The floor a flex column may shrink to before the table starts scrolling horizontally.
  /// Without this, a narrow window silently ellipsises every cell to two characters and the
  /// table becomes a grid of "…".
  final double minWidth;

  final bool sortable;

  /// The row's state AS SEEN BY THIS COLUMN — what colours a [AbColumnType.badge] pill.
  final AbSeverity Function(T row)? severity;

  /// An escape hatch for a column whose order is not derivable from its text (a status that
  /// sorts by seriousness rather than alphabetically). Return the usual `-1/0/1`; the table
  /// applies direction and the index tiebreak around it.
  final int Function(T a, T b)? compare;

  final TextAlign? align;

  /// Numbers right-align so their digits line up against each other; everything else reads from
  /// the left like text does.
  TextAlign get effectiveAlign =>
      align ?? (type == AbColumnType.number ? TextAlign.right : TextAlign.left);

  /// Order two rows by this column, ascending. Type-aware, so the table never has to ask what
  /// it is sorting.
  int compareRows(T a, T b) {
    final custom = compare;
    if (custom != null) return custom(a, b);
    final left = value(a);
    final right = value(b);
    switch (type) {
      case AbColumnType.number:
        final ln = num.tryParse(left.trim());
        final rn = num.tryParse(right.trim());
        // Unparseable values (the em-dash placeholder, "n/a") sort to the END in both
        // directions' natural reading: they are the absence of a number, not a small one.
        if (ln == null && rn == null) {
          return AbNaturalOrder.compare(left, right);
        }
        if (ln == null) return 1;
        if (rn == null) return -1;
        return ln.compareTo(rn);
      case AbColumnType.date:
        final ld = DateTime.tryParse(left.trim());
        final rd = DateTime.tryParse(right.trim());
        if (ld == null && rd == null) {
          return AbNaturalOrder.compare(left, right);
        }
        if (ld == null) return 1;
        if (rd == null) return -1;
        return ld.compareTo(rd);
      case AbColumnType.text:
      case AbColumnType.mono:
      case AbColumnType.badge:
        return AbNaturalOrder.compare(left, right);
    }
  }
}

/// Human ordering for strings that contain numbers.
///
/// Stands in for Foundation's `localizedStandardCompare`, which is what the Swift app sorted
/// with — dropping to a plain `String.compareTo` in the port would have quietly regressed every
/// version, model and serial column ("iPhone 10" before "iPhone 9"; "10.2" before "9.1").
///
/// Hand-rolled rather than pulled from a package because this port adds no dependencies, and
/// written as an index scan rather than a `RegExp` split because it runs O(n log n) times over
/// tables of thousands of rows — allocating two match lists per comparison is how a sort click
/// turns into a visible stall.
abstract final class AbNaturalOrder {
  static int compare(String a, String b) {
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      final ca = a.codeUnitAt(i);
      final cb = b.codeUnitAt(j);
      if (_isDigit(ca) && _isDigit(cb)) {
        final endA = _digitRunEnd(a, i);
        final endB = _digitRunEnd(b, j);
        final order = _compareDigitRuns(
          a.substring(i, endA),
          b.substring(j, endB),
        );
        if (order != 0) return order;
        i = endA;
        j = endB;
        continue;
      }
      // Case-insensitive by default so "iPad" and "iPAD" interleave the way a person expects a
      // sorted list to read; case only ever breaks an otherwise exact tie, below.
      final la = _lower(ca);
      final lb = _lower(cb);
      if (la != lb) return la < lb ? -1 : 1;
      i++;
      j++;
    }
    if (i < a.length) return 1;
    if (j < b.length) return -1;
    // Same letters, same numbers: fall back to the exact bytes so "AB" and "ab" have a stable
    // (if arbitrary) order instead of comparing equal and being left to the index tiebreak.
    return a.compareTo(b);
  }

  /// Compare two runs of digits by VALUE, without parsing them. An Apple resource id can be
  /// forty digits long — `int.parse` would overflow or throw, and this only needs the ordering.
  static int _compareDigitRuns(String a, String b) {
    final ta = _stripLeadingZeros(a);
    final tb = _stripLeadingZeros(b);
    if (ta.length != tb.length) return ta.length < tb.length ? -1 : 1;
    final order = ta.compareTo(tb);
    if (order != 0) return order < 0 ? -1 : 1;
    // Equal in value: the one written with fewer leading zeros comes first, so "007" and "7"
    // never compare equal and swap places between rebuilds.
    return a.length == b.length ? 0 : (a.length < b.length ? -1 : 1);
  }

  static String _stripLeadingZeros(String run) {
    var start = 0;
    while (start < run.length - 1 && run.codeUnitAt(start) == 0x30) {
      start++;
    }
    return run.substring(start);
  }

  static int _digitRunEnd(String s, int from) {
    var end = from;
    while (end < s.length && _isDigit(s.codeUnitAt(end))) {
      end++;
    }
    return end;
  }

  static bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

  /// ASCII-only lowering. Enough for the data this app shows (Apple's identifiers, models and
  /// serials are ASCII) and free of the allocation `toLowerCase()` would cost per character.
  static int _lower(int code) =>
      (code >= 0x41 && code <= 0x5A) ? code + 32 : code;
}

/// Timestamps, in the two forms a table needs.
///
/// A raw `2026-07-11T04:22:19Z` in a cell is precise and unreadable; "3h ago" is readable and
/// imprecise. The table shows the second and puts the first on hover, so scanning is fast and
/// the exact value is always one hover away — the Swift audit table only ever had the first.
///
/// Formatted by hand because `intl` is not a dependency here. The absolute form is deliberately
/// ISO-8601-shaped: it is what abctl prints, so a value copied out of the GUI matches a value
/// copied out of the CLI.
abstract final class AbRelativeTime {
  static String short(DateTime when, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final delta = reference.difference(when);
    // Future timestamps are real: an expiry date, or a machine whose clock is ahead of ours.
    // Saying "in 4d" is honest where "4d ago" would be a lie about the same data.
    final ahead = delta.isNegative;
    final span = ahead ? -delta : delta;
    if (span.inSeconds < 45) return ahead ? 'in a moment' : 'just now';
    final String magnitude;
    if (span.inMinutes < 60) {
      magnitude = '${span.inMinutes}m';
    } else if (span.inHours < 24) {
      magnitude = '${span.inHours}h';
    } else if (span.inDays < 7) {
      magnitude = '${span.inDays}d';
    } else {
      // Past a week, relative stops being useful ("63d ago" is not a date anyone can place) and
      // the calendar day is the more informative answer.
      return absolute(when, includeTime: false);
    }
    return ahead ? 'in $magnitude' : '$magnitude ago';
  }

  static String absolute(DateTime when, {bool includeTime = true}) {
    final local = when.toLocal();
    final date =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    if (!includeTime) return date;
    final time =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
    return '$date $time';
  }
}
