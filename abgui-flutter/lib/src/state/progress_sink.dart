// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';

/// The live transcript of a long-running command: abctl's stderr narration plus abgui's own
/// `$ abctl diff …` / `→ exit 0 in 2.4s` lines, coalesced onto a 100 ms tick.
///
/// **This type lives OUTSIDE Riverpod deliberately, and that decision removes an entire class of
/// bug rather than an instance of one.** abctl narrates per configuration, so a plan against a
/// real tenant arrives as a burst of hundreds of stderr lines. In the Swift app each line was
/// appended straight into the `@Observable` model: every line re-evaluated the Diff view's body,
/// rebuilt the whole transcript by joining up to 200 lines, and animated a scroll — hundreds of
/// full-window invalidations while the run was working hardest. A starved main actor does not draw
/// a partial UI; it draws NOTHING, so the window (sidebar included) went blank and the run looked
/// hung. The more configurations the tenant had, the worse it got.
///
/// Holding the lines in a provider would reproduce that exactly: `state = [...state, line]` per
/// line invalidates every dependent of that provider, which in Riverpod means rebuilding whatever
/// watches it and re-running whatever selects from it — per line, on the platform thread that also
/// has to draw. Per-line provider invalidation IS the starvation bug in a new language.
///
/// So: a plain [ValueNotifier] fed by a coalescing timer. Exactly one widget listens
/// (a `ValueListenableBuilder` around the transcript), so a burst repaints that subtree and
/// nothing above it — the sidebar, the plan table and the connection footer are not even
/// consulted. One view update per 100 ms window instead of one per line. Nothing is dropped or
/// reordered: [mirror] still receives every line, in order, for the on-disk run log.
class ProgressSink {
  ProgressSink({
    this.cap = defaultCap,
    this.flushInterval = const Duration(milliseconds: 100),
  });

  /// How many lines stay on screen. The FILE keeps everything (see [mirror]); this cap exists
  /// only so a 20-minute run cannot grow a scroll view without bound, and truncating the evidence
  /// for the same reason would defeat the point of having a log.
  static const int defaultCap = 200;

  final int cap;
  final Duration flushInterval;

  /// The published transcript. Replaced wholesale on each flush — a new list object every time,
  /// which is what makes `ValueNotifier`'s identity check fire; mutating a shared list in place
  /// would notify nobody.
  final ValueNotifier<List<String>> lines = ValueNotifier<List<String>>(
    const <String>[],
  );

  /// Every line, uncapped and un-coalesced, for the on-disk run log. Set by whoever owns the open
  /// log (the GitOps store). It is a stable closure over that store's "currently open log" field
  /// rather than a tear-off of one particular log, so a run that supersedes another cannot leave
  /// the sink writing into the file its predecessor closed.
  void Function(String line)? mirror;

  final List<String> _pending = <String>[];
  Timer? _timer;
  bool _disposed = false;

  /// Buffered lines waiting for the next tick. For tests and for [addNow]'s ordering guarantee.
  @visibleForTesting
  int get pendingCount => _pending.length;

  /// Buffer one streamed line. Called once per stderr line, so it must stay O(1) and must not
  /// touch [lines] — this is the hot path the coalescer exists for.
  void add(String line) {
    if (_disposed) return;
    _pending.add(line);
    // One timer in flight, never one per line: a 2,000-line plan schedules 2,000 timers
    // otherwise, and each one costs a wake-up on the thread that draws.
    _timer ??= Timer(flushInterval, () {
      _timer = null;
      flush();
    });
  }

  /// Append a line that must not overtake anything already buffered, publishing immediately.
  ///
  /// This is the ordering-critical path: `→ exit 0 in 2.4s` describes a command whose narration is
  /// sitting in the buffer, so it flushes first and then publishes. Without the flush the finish
  /// line would appear ABOVE the output of the command it is reporting on, which reads as the next
  /// command's transcript starting early.
  void addNow(String line) {
    if (_disposed) return;
    _pending.add(line);
    flush();
  }

  /// Publish everything buffered — one notification, whatever the batch size. A no-op when
  /// nothing is pending, so it is safe to call at the end of every run.
  void flush() {
    if (_disposed || _pending.isEmpty) return;
    final batch = List<String>.of(_pending);
    _pending.clear();
    final mirrorLine = mirror;
    if (mirrorLine != null) {
      for (final line in batch) {
        // The file gets the line before the screen does and is never trimmed: a run whose failure
        // is being reported must have its complete transcript on disk, whatever the UI kept.
        mirrorLine(line);
      }
    }
    final combined = <String>[...lines.value, ...batch];
    lines.value = combined.length <= cap
        ? List<String>.unmodifiable(combined)
        : List<String>.unmodifiable(combined.sublist(combined.length - cap));
  }

  /// Start a new transcript: drop the buffered tail along with what is on screen.
  ///
  /// The drop is the point. Without it the PREVIOUS run's unflushed lines land in the NEXT run's
  /// transcript a tick later, which is how a diff came to be narrated with the tail of the seed
  /// that preceded it. Called before the new run's first line, never after it.
  void clear() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    lines.value = const <String>[];
  }

  /// Idempotent, and it cancels the timer: a live timer outlives the widget tree in a test and
  /// keeps the isolate's event loop awake for the rest of the flush interval in the app.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    mirror = null;
    lines.dispose();
  }
}
