// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The coalescer. What is under test is not "lines arrive" but the RATE at which the UI is asked to
// redraw: a plan against a real tenant arrives as a burst of hundreds of stderr lines, and one
// notification per line is what blanked the Swift window mid-run.
//
// Real timers with a short interval rather than a fake clock: the sink is a plain object with no
// binding, and a `testWidgets` fake clock would also make the "nothing has been published yet"
// assertions less honest than they look — here they hold because the adds are synchronous, which
// is the property the coalescer actually relies on.

import 'package:abgui/src/state/progress_sink.dart';
import 'package:flutter_test/flutter_test.dart';

/// Long enough to cover the sink's own interval several times over on a loaded CI box.
const Duration _afterFlush = Duration(milliseconds: 120);

ProgressSink _sink({int cap = ProgressSink.defaultCap}) =>
    ProgressSink(cap: cap, flushInterval: const Duration(milliseconds: 20));

void main() {
  test('the shipped interval is the one the Swift app landed on', () {
    final sink = ProgressSink();
    expect(sink.flushInterval, const Duration(milliseconds: 100));
    sink.dispose();
  });

  test('a burst of lines costs ONE notification, not one per line', () async {
    final sink = _sink();
    var notifications = 0;
    sink.lines.addListener(() => notifications += 1);

    for (var i = 0; i < 200; i++) {
      sink.add('fetching profile $i');
    }

    // Nothing has reached the UI yet: the adds are synchronous, so no tick can have run between
    // them. This is the whole trick — 200 lines, zero rebuilds so far.
    expect(notifications, 0);
    expect(sink.lines.value, isEmpty);
    expect(sink.pendingCount, 200);

    await Future<void>.delayed(_afterFlush);

    expect(notifications, 1);
    expect(sink.lines.value, hasLength(200));
    expect(sink.lines.value.first, 'fetching profile 0');
    expect(sink.lines.value.last, 'fetching profile 199');
    sink.dispose();
  });

  test('nothing is dropped or reordered across two windows', () async {
    final sink = _sink();
    sink
      ..add('one')
      ..add('two');
    await Future<void>.delayed(_afterFlush);
    sink
      ..add('three')
      ..add('four');
    await Future<void>.delayed(_afterFlush);

    expect(sink.lines.value, <String>['one', 'two', 'three', 'four']);
    sink.dispose();
  });

  test('addNow flushes first, so it cannot overtake buffered output', () async {
    final sink = _sink();
    sink
      ..add('abctl: fetching configurations')
      ..add('abctl: fetching blueprints');

    // The recorder's `→ exit 0 in 2.4s` line describes a command whose narration is still in the
    // buffer. Published ahead of it, it would read as the NEXT command's transcript starting.
    sink.addNow('→ exit 0 in 2.4s');

    expect(sink.lines.value, <String>[
      'abctl: fetching configurations',
      'abctl: fetching blueprints',
      '→ exit 0 in 2.4s',
    ]);
    expect(sink.pendingCount, 0);
    sink.dispose();
  });

  test(
    'the on-screen cap trims the oldest, and the mirror keeps everything',
    () async {
      final sink = _sink(cap: 3);
      final mirrored = <String>[];
      sink.mirror = mirrored.add;

      for (var i = 0; i < 6; i++) {
        sink.add('line $i');
      }
      await Future<void>.delayed(_afterFlush);

      // The screen keeps the tail; the file (mirror) is never trimmed, because truncating the
      // evidence for the sake of a scroll view defeats the point of having a log.
      expect(sink.lines.value, <String>['line 3', 'line 4', 'line 5']);
      expect(mirrored, hasLength(6));
      expect(mirrored.first, 'line 0');
      sink.dispose();
    },
  );

  test(
    'clear() drops the buffered tail so it cannot flush into the next run',
    () async {
      final sink = _sink();
      sink
        ..add('previous run, line 1')
        ..add('previous run, line 2');

      // A new run starts before the old one's buffer ticked. Without the drop, those two lines land
      // at the TOP of the new transcript a tick later.
      sink.clear();
      sink.add(r'$ abctl diff --json');
      await Future<void>.delayed(_afterFlush);

      expect(sink.lines.value, <String>[r'$ abctl diff --json']);
      sink.dispose();
    },
  );

  test(
    'a disposed sink accepts lines without throwing and never fires again',
    () async {
      final sink = _sink();
      var notifications = 0;
      sink.lines.addListener(() => notifications += 1);
      sink.add('mid-run');
      sink.dispose();

      // The window can close while abctl is still narrating; the stderr stream does not know that.
      sink
        ..add('after dispose')
        ..addNow('after dispose too')
        ..flush();
      await Future<void>.delayed(_afterFlush);

      expect(notifications, 0);
    },
  );
}
