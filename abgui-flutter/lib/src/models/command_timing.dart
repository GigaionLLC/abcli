// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'command_record.dart';

// Port note: Swift keeps `DurationText` in this file. Here it lives next to `CommandRecord`,
// whose `durationText` is its first caller — importing the roll-up from the record just to
// format a duration would invert the dependency (the timing panel is built FROM records) and
// make the two files import each other.

/// Timing rolled up per abctl verb, from the invocations abgui has already recorded.
///
/// Every command runs through the one runner seam and is timed there (the recording runner →
/// `CommandRecord.duration`), so this needs no new instrumentation — the numbers exist, they
/// were just never added up. The chronological log answers "what did this run do"; this
/// answers the question that actually finds a performance bug: "which verb is slow, is it slow
/// EVERY time, and is one of them still running right now?"
class CommandTiming {
  /// The verb as a human would name it: `diff`, `get configurations`, `adopt config`.
  final String verb;
  final int runs;
  final int failures;
  final Duration totalDuration;
  final Duration slowest;

  /// Invocations of this verb that have not finished yet — the "is it still loading?" signal.
  final int running;

  const CommandTiming({
    required this.verb,
    this.runs = 0,
    this.failures = 0,
    this.totalDuration = Duration.zero,
    this.slowest = Duration.zero,
    this.running = 0,
  });

  String get id => verb;

  Duration get average => runs == 0
      ? Duration.zero
      : Duration(microseconds: totalDuration.inMicroseconds ~/ runs);

  /// Roll up finished AND in-flight records, slowest verb first. Ties break on name so the
  /// order is stable while a run is in flight and the list is re-rendering every second.
  static List<CommandTiming> rollUp(List<CommandRecord> records) {
    final byVerb = <String, _Accumulator>{};
    for (final record in records) {
      final key = verbKey(record.argv);
      final entry = byVerb.putIfAbsent(key, () => _Accumulator(key));
      final duration = record.duration;
      if (record.status == CommandStatus.running) {
        entry.running += 1;
      } else if (duration != null) {
        // An unfinished command contributes NO duration — otherwise a command that never
        // returns would read as instant, which is the opposite of what this panel is for.
        entry.runs += 1;
        entry.totalDuration += duration;
        if (duration > entry.slowest) entry.slowest = duration;
      }
      if (record.isFailure) entry.failures += 1;
    }
    final rolled = byVerb.values.map((a) => a.freeze()).toList();
    rolled.sort(
      (a, b) => a.slowest == b.slowest
          ? a.verb.compareTo(b.verb)
          : b.slowest.compareTo(a.slowest),
    );
    return rolled;
  }

  /// The leading argv tokens that name the operation: the verb, plus its subject when there is
  /// one (`get configurations`, `adopt config`). Stops at the first flag, so `--json` and a
  /// tenant-specific `--blueprint <name>` never fragment one verb into many rows — the whole
  /// point is to compare repeated runs of the same operation against each other.
  static String verbKey(List<String> argv) {
    final words = argv
        .takeWhile((a) => !a.startsWith('-'))
        .take(2)
        .toList(growable: false);
    return words.isEmpty ? 'abctl' : words.join(' ');
  }

  @override
  bool operator ==(Object other) =>
      other is CommandTiming &&
      other.verb == verb &&
      other.runs == runs &&
      other.failures == failures &&
      other.totalDuration == totalDuration &&
      other.slowest == slowest &&
      other.running == running;

  @override
  int get hashCode =>
      Object.hash(verb, runs, failures, totalDuration, slowest, running);

  @override
  String toString() => 'CommandTiming($verb runs=$runs slowest=$slowest)';
}

/// The one mutable thing in this layer, and it never escapes [CommandTiming.rollUp]: Swift
/// accumulates into a `var` copy of the struct, which Dart's final fields cannot do.
class _Accumulator {
  _Accumulator(this.verb);

  final String verb;
  int runs = 0;
  int failures = 0;
  Duration totalDuration = Duration.zero;
  Duration slowest = Duration.zero;
  int running = 0;

  CommandTiming freeze() => CommandTiming(
    verb: verb,
    runs: runs,
    failures: failures,
    totalDuration: totalDuration,
    slowest: slowest,
    running: running,
  );
}

extension CommandRecordTiming on CommandRecord {
  /// Wall-clock time this command has taken: its final duration once finished, else how long
  /// it has been running as of [asOf]. Feeding the clock in (rather than reading it here) is
  /// what lets a view tick this from a timer and keeps it testable.
  Duration elapsed({DateTime? asOf}) {
    final done = duration;
    if (done != null) return done;
    final now = asOf ?? DateTime.now();
    final since = now.difference(startedAt);
    return since.isNegative ? Duration.zero : since;
  }

  /// Long enough that a person notices the wait. Used only to draw attention in the log — it
  /// marks nothing as broken, and abgui's real limits are the per-verb timeouts in the client.
  static const Duration slowThreshold = Duration(seconds: 5);

  bool isSlow({DateTime? asOf}) =>
      elapsed(asOf: asOf) >= CommandRecordTiming.slowThreshold;
}
