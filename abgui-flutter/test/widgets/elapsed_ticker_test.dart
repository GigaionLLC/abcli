// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/elapsed_ticker.dart';

void main() {
  final DateTime start = DateTime(2026, 8, 15, 12);

  Widget wrap(Widget child) => MaterialApp(
    theme: abTheme(Brightness.light),
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('ticks while running, without rebuilding its ancestor', (
    WidgetTester tester,
  ) async {
    var now = start;
    var ancestorBuilds = 0;

    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (BuildContext context) {
            ancestorBuilds++;
            return ElapsedTicker(startedAt: start, clock: () => now);
          },
        ),
      ),
    );

    expect(find.text('0.0s'), findsOneWidget);
    expect(ancestorBuilds, 1);

    now = start.add(const Duration(milliseconds: 2500));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('2.5s'), findsOneWidget);

    now = start.add(const Duration(seconds: 64));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('1m 4s'), findsOneWidget);

    // THE POINT OF THIS WIDGET. The timer lives at the leaf, so twice a second it dirties one
    // Text and nothing above it. If this ever climbs, a console with a long plan on screen is
    // re-laying out thousands of rows to move a digit — which is exactly what the Swift app's
    // TimelineView did.
    expect(ancestorBuilds, 1);

    // Dispose the tree: a surviving periodic timer fails the test, which is how the "stops when
    // idle" promise stays honest.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a finished command freezes and holds no timer', (
    WidgetTester tester,
  ) async {
    var now = start.add(const Duration(seconds: 3));

    await tester.pumpWidget(
      wrap(ElapsedTicker(startedAt: start, clock: () => now)),
    );
    expect(find.text('3.0s'), findsOneWidget);

    // The record is replaced (not mutated) when the command ends, so the finish arrives as a new
    // widget configuration — this is what actually retires the timer in production.
    await tester.pumpWidget(
      wrap(
        ElapsedTicker(
          startedAt: start,
          finishedAt: start.add(const Duration(seconds: 4)),
          clock: () => now,
        ),
      ),
    );
    expect(find.text('4.0s'), findsOneWidget);

    // The clock keeps moving; the reading must not.
    now = start.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('4.0s'), findsOneWidget);
    // No pending-timer failure at teardown = the timer was cancelled, with no tree swap needed.
  });

  testWidgets('never prints a negative duration', (WidgetTester tester) async {
    // A machine whose clock steps backwards mid-run (NTP correction, a VM resuming) would
    // otherwise render "-3.0s", which reads as a bug in abctl rather than in the clock.
    await tester.pumpWidget(
      wrap(
        ElapsedTicker(
          startedAt: start,
          finishedAt: start.subtract(const Duration(seconds: 3)),
        ),
      ),
    );
    expect(find.text('0.0s'), findsOneWidget);
  });
}
