// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:abgui/src/models/command_record.dart';
import 'package:abgui/src/models/command_timing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Every abctl invocation abgui has made this session, newest LAST.
///
/// abgui is a thin facade over a CLI, so this doubles as the answer to "how would I do that in a
/// terminal?" — the records are the redacted argv the app really ran. Nothing is instrumented per
/// callsite: the `RecordingRunner` wraps the one runner seam, so verbs added later are captured
/// without anyone remembering to.
class CommandLog {
  const CommandLog({this.records = const <CommandRecord>[]});

  /// Append order, so a list view scrolls naturally and `last` is the newest.
  final List<CommandRecord> records;

  /// What the connection footer shows as "the last thing abgui ran".
  CommandRecord? get last => records.isEmpty ? null : records.last;

  bool get isEmpty => records.isEmpty;

  /// In-flight invocations. The honest answer to "is anything running right now?" for a status
  /// bar — as opposed to an app-wide `isLoading`, which is a claim about screens rather than
  /// about work and is exactly what this layer refuses to have.
  int get runningCount =>
      records.where((r) => r.status.kind == CommandStatusKind.running).length;

  /// Per-verb roll-up, slowest first. Derived rather than stored: it is a pure function of
  /// [records], and a second copy of the numbers is a second thing that can be stale. It is
  /// O(records) over a list capped at 200, and it is computed once per change by
  /// `commandTimingProvider` — not once per widget that draws it.
  List<CommandTiming> get timings => CommandTiming.rollUp(records);

  @override
  bool operator ==(Object other) =>
      other is CommandLog && identical(other.records, records);

  /// Identity, matching `==`. The list is replaced on every change and never mutated, so identity
  /// IS value equality here — and a real element-wise compare would run on every notification
  /// over records whose own `==` compares seven fields each.
  @override
  int get hashCode => identityHashCode(records);
}

/// The trail, capped. One notification per command start and one per finish — two per command,
/// which is a rate a UI can absorb (contrast the progress transcript, which is per LINE and is
/// therefore not in Riverpod at all; see `progress_sink.dart`).
class CommandLogStore extends Notifier<CommandLog> {
  /// Same cap as the Swift original. A long session must not grow this without bound, and the
  /// interesting commands are always the recent ones — the on-disk run log is where a complete
  /// history of a single run lives.
  static const int limit = 200;

  @override
  CommandLog build() => const CommandLog();

  /// Record an invocation the instant it starts, so the UI can show it while the child is still
  /// running rather than only in hindsight. The record arrives already redacted (`CommandRecord`
  /// redacts in its constructor), so no secret can enter this state.
  void start(CommandRecord record) {
    final next = <CommandRecord>[...state.records, record];
    state = CommandLog(
      records: next.length <= limit ? next : next.sublist(next.length - limit),
    );
  }

  /// Stamp the terminal status and hand the finished record back, so the caller can narrate
  /// `→ exit 0 in 2.4s` from [CommandRecord.finishLogLine] instead of re-deriving that text.
  ///
  /// Null means the record aged out of the cap (or never started) — there is nothing truthful to
  /// print, and inventing a line for a command whose start nobody can see is worse than silence.
  CommandRecord? finish(String id, CommandStatus status) {
    final index = state.records.lastIndexWhere((r) => r.id == id);
    if (index < 0) return null;
    final finished = state.records[index].copyWith(
      finishedAt: DateTime.now(),
      status: status,
    );
    final next = <CommandRecord>[...state.records];
    next[index] = finished;
    state = CommandLog(records: next);
    return finished;
  }

  void clear() {
    state = const CommandLog();
  }
}
