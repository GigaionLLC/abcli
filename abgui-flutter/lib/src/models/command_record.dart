// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

import 'package:abgui/src/abctl/command_formatter.dart';

// CONSOLIDATION NOTE. This file is the merge of two independently written ports of the same
// Swift type: this one and a second copy that lived at `lib/src/abctl/command_record.dart`
// (now deleted). The rules the merge followed:
//
//  * HOME. `Models/CommandRecord.swift` is the Swift original and this is a DATA type, not
//    process machinery, so it lives in `models/` and the `abctl/` layer imports it. The one
//    piece that is genuinely CLI knowledge — quoting, `-f -` rewriting, the `cd` line — moved
//    the other way, into `lib/src/abctl/command_formatter.dart`.
//
//  * ENUM NAME: `CommandStatusKind`, not the other copy's `CommandOutcome`. The two named the
//    same concept, but the enum is only ever spelled at one kind of call site — reading
//    `CommandStatus.kind` — and `status.kind == CommandStatusKind.failed` says which type the
//    value belongs to, where `CommandOutcome.failed` reads as a second, unrelated concept
//    sitting next to `CommandStatus`. It also matches the `<Thing>Kind` spelling this package
//    already uses for exactly this pattern (`SyncFailureKind`, `ReadOnlyKind`).
//
//  * WHERE THE COPIES DISAGREED, the safer or richer member won and nothing was dropped. Each
//    of those decisions is commented at the member, naming the copy it came from.

/// How the invocation ended. [CommandStatusKind.running] until the child exits.
///
/// Port note: Swift models this as an enum with an associated `Int32` on the failed case. Dart
/// enums cannot carry a payload, so it is a value class with a const constructor per case —
/// `CommandStatus.running`, `const CommandStatus.failed(3)` — which keeps call sites reading
/// like the Swift ones and keeps the exit code attached to the case that owns it.
///
/// One value type with a kind + code rather than a hand-written sealed hierarchy: the exit code
/// is meaningful for exactly one kind, and every consumer needs `==`, which a sealed hierarchy
/// would have to re-implement per case.
class CommandStatus {
  const CommandStatus._(this.kind, [this.exitCode]);

  /// A failure carrying abctl's exit code.
  const CommandStatus.failed(int code) : this._(CommandStatusKind.failed, code);

  static const CommandStatus running = CommandStatus._(
    CommandStatusKind.running,
  );
  static const CommandStatus succeeded = CommandStatus._(
    CommandStatusKind.succeeded,
  );

  /// The user pressed Cancel — deliberately NOT a failure.
  static const CommandStatus cancelled = CommandStatus._(
    CommandStatusKind.cancelled,
  );

  /// abgui's own guardrail fired. It gets its own kind instead of masquerading as an exit
  /// code, because `exit -1` would read as a real result abctl returned.
  static const CommandStatus timedOut = CommandStatus._(
    CommandStatusKind.timedOut,
  );

  final CommandStatusKind kind;

  /// The child's exit code — only meaningful for [CommandStatusKind.failed].
  ///
  /// NULLABLE (models copy); the abctl copy made it a non-nullable `int` defaulted to 0. Null
  /// is the safer of the two: with a default of 0 a `running` or `cancelled` status reports
  /// `exitCode == 0`, which is indistinguishable from a real, successful exit for anyone who
  /// reads the field without first checking [kind].
  final int? exitCode;

  /// The one rendering of a status (abctl copy). The models copy spelled the same switch out on
  /// the record as `statusText`; that is now a delegate to this, so the two cannot disagree.
  String get text {
    switch (kind) {
      case CommandStatusKind.running:
        return 'running';
      case CommandStatusKind.succeeded:
        return 'exit 0';
      case CommandStatusKind.failed:
        return 'exit $exitCode';
      case CommandStatusKind.cancelled:
        return 'cancelled';
      case CommandStatusKind.timedOut:
        return 'timed out';
    }
  }

  /// A timeout counts as a failure; a cancellation does not — the user asked for it.
  bool get isFailure =>
      kind == CommandStatusKind.failed || kind == CommandStatusKind.timedOut;

  @override
  bool operator ==(Object other) =>
      other is CommandStatus &&
      other.kind == kind &&
      other.exitCode == exitCode;

  @override
  int get hashCode => Object.hash(kind, exitCode);

  /// The DEBUG form (models copy), not the UI string: the abctl copy returned [text] here, but
  /// that string is already available under a name that says it is for display, and `exit 0` in
  /// a failed expectation reads as an answer rather than as the value that produced it.
  @override
  String toString() =>
      kind == CommandStatusKind.failed ? 'failed($exitCode)' : kind.name;
}

/// The five ways an invocation can end, as [CommandStatus.kind].
enum CommandStatusKind { running, succeeded, failed, cancelled, timedOut }

/// What abgui fed the child on stdin. Only the SIZE is kept — never the content — but it is
/// enough for the copyable form to rewrite `-f -` into a real file path, since a pasted
/// `-f -` would otherwise sit waiting on an empty terminal forever.
class CommandStdin {
  const CommandStdin._(this.bytes);

  /// A CONSTRUCTOR (abctl copy), where the models copy had a `static const CommandStdin none`
  /// field. Dart cannot have both under one name, and `const CommandStdin.none()` is what the
  /// default arguments in `process_runner.dart`, `run_log.dart` and [CommandFormatter.script]
  /// already spell.
  const CommandStdin.none() : this._(null);

  /// `bytes` is non-nullable here on purpose: "a profile of unknown size" is not a state this
  /// type is allowed to represent, because the copyable script has to name the size.
  ///
  /// The argument is NAMED (abctl copy); the models copy took it positionally. A bare
  /// `CommandStdin.profile(2048)` beside a type whose entire point is "the size and nothing
  /// else" is the number a reader is most likely to mistake for a payload or an id.
  const CommandStdin.profile({required int bytes}) : this._(bytes);

  /// null means nothing was piped in. There is no field for the payload, and adding one
  /// would defeat the point of the type.
  ///
  /// Named `bytes` (abctl copy) rather than the models copy's `profileBytes`: `RunLog`'s header
  /// reads `header.stdin.bytes`, and the type's own name already says whose bytes these are.
  final int? bytes;

  /// Both copies' predicates survive — the abctl copy asked [isEmpty], the models copy asked
  /// [isProfile] — because each reads correctly on its own side of the question.
  bool get isEmpty => bytes == null;

  bool get isProfile => bytes != null;

  @override
  bool operator ==(Object other) =>
      other is CommandStdin && other.bytes == bytes;

  @override
  int get hashCode => bytes.hashCode;

  @override
  String toString() => bytes == null ? 'none' : 'profile($bytes bytes)';
}

/// One abctl invocation abgui made, recorded so an administrator can see — and reproduce —
/// exactly what the GUI did. abgui is a thin facade over the CLI, so every button ultimately
/// IS an abctl command; surfacing it turns the app into documentation for its own backend.
///
/// `argv` is REDACTED at construction: a secret-bearing value can never enter this type, so
/// nothing downstream (the command log, a copy button, a progress line, a screenshot in a
/// support ticket) can leak one. There is deliberately no way to recover the raw argv here —
/// which is why the redacting constructor is the only public one and [CommandRecord._raw] is
/// private.
///
/// Ported from the Swift `CommandRecord`. It is IMMUTABLE here where Swift got value
/// semantics for free from `struct`: a record travels into UI state that rebuilds off
/// equality, and a mutable object shared between the runner and the list would let the
/// runner mutate a row the UI has already decided is unchanged. Use [copyWith] to record
/// the outcome, exactly as the Swift code assigned into its `var` copy.
class CommandRecord {
  /// Redaction happens HERE, in the initializer, and nowhere else: the invariant is that a
  /// `CommandRecord` holding a secret cannot be constructed, so no downstream reviewer has
  /// to check whether some particular call site remembered to redact.
  ///
  /// [finishedAt] is settable (abctl copy; the models copy's factory hard-coded it to null),
  /// so a record reconstructed from something already complete does not have to be built
  /// running and then immediately closed.
  CommandRecord({
    required List<String> argv,
    this.cwd,
    this.stdin = const CommandStdin.none(),
    this.status = CommandStatus.running,
    DateTime? startedAt,
    String? id,
    this.finishedAt,
  }) : argv = CommandFormatter.redact(argv),
       startedAt = startedAt ?? DateTime.now(),
       id = id ?? newId();

  const CommandRecord._raw({
    required this.id,
    required this.argv,
    required this.cwd,
    required this.startedAt,
    required this.finishedAt,
    required this.status,
    required this.stdin,
  });

  /// Stable identity for the row in the command log.
  final String id;

  /// Redacted argv, WITHOUT the leading "abctl" (the formatter adds it). Unmodifiable — see
  /// [CommandFormatter.redact].
  final List<String> argv;

  /// The working directory the command ran in, as a path. Load-bearing, not decoration:
  /// `diff`/`sync` resolve the `gitops/` tree relative to it, so a copied command is wrong
  /// without the `cd`.
  final String? cwd;

  final DateTime startedAt;
  final DateTime? finishedAt;
  final CommandStatus status;
  final CommandStdin stdin;

  /// The Swift record is a struct whose `finishedAt`/`status`/`stdin` are `var`s the runner
  /// mutates when the child exits. Dart's model layer is immutable, so closing a record
  /// produces a new one — same id, so the log row it replaces is still the same row.
  ///
  /// It goes through the private raw constructor so `argv` is carried over as-is: it is
  /// ALREADY redacted, and re-entering the public constructor would run the redactor a second
  /// time — harmless today (it is idempotent) but exactly the kind of "it gets redacted
  /// somewhere" reasoning this type exists to make unnecessary.
  ///
  /// `stdin` is copyable too (models copy); the abctl copy's `copyWith` took only `finishedAt`
  /// and `status`.
  CommandRecord copyWith({
    DateTime? finishedAt,
    CommandStatus? status,
    CommandStdin? stdin,
  }) => CommandRecord._raw(
    id: id,
    argv: argv,
    cwd: cwd,
    startedAt: startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    status: status ?? this.status,
    stdin: stdin ?? this.stdin,
  );

  /// Wall-clock time the child ran, once it has finished.
  Duration? get duration {
    final end = finishedAt;
    if (end == null) return null;
    final elapsed = end.difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// The command as a single copy-pasteable line: `abctl sync --apply --yes`.
  String get commandLine => CommandFormatter.line(argv);

  /// The full reproduction snippet: `cd` into the workspace, the command, and a note when
  /// abgui piped a profile in on stdin.
  String get script =>
      CommandFormatter.script(argv: argv, cwd: cwd, stdin: stdin);

  /// What the GitOps progress logs print when the command starts. The `$` prefix is what makes
  /// these lines read as a shell transcript rather than as more of abctl's narration.
  String get startLogLine => '\$ $commandLine';

  /// The matching completion line: `→ exit 0 in 2.4s`.
  String get finishLogLine {
    final text = durationText;
    if (text == null) return '→ $statusText';
    return '→ $statusText in $text';
  }

  String get statusText => status.text;

  String? get durationText {
    final d = duration;
    // One formatter, shared with the timing panel.
    return d == null ? null : DurationText.short(d);
  }

  bool get isFailure => status.isFailure;

  /// Swift gets a `UUID()` from Foundation; Dart has no built-in UUID and this port adds no
  /// dependencies, so the id is 32 random hex digits laid out in the same shape. It only has
  /// to be unique within one app run — it keys a log row, it is never persisted, and it is
  /// never compared across processes or machines.
  ///
  /// The models copy's body wins over the abctl copy's (which drew from a `Random()` built
  /// fresh on every call): one shared generator cannot hand two records built in the same
  /// instant the same seed, and the dashed UUID shape is what `RunLog.shortId` already strips
  /// before taking its first six hex digits. The abctl copy's shorter name, `newId`, wins over
  /// `newRecordID` — it is already what `RunLog.begin` calls, and `CommandRecord.newId()` says
  /// whose id it is without repeating the type.
  static String newId() {
    const hex = '0123456789abcdef';
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      if (i == 8 || i == 12 || i == 16 || i == 20) buffer.write('-');
      buffer.write(hex[_random.nextInt(16)]);
    }
    return buffer.toString();
  }

  static final Random _random = Random();

  /// FULL value equality (abctl copy), not the models copy's id-only comparison. Id-only is the
  /// dangerous half of the pair: [copyWith] deliberately keeps the id, so a finished record
  /// would compare EQUAL to the running one it replaces, and a UI (or a `Set`, or a list diff)
  /// that rebuilds off equality would never notice the command had ended.
  @override
  bool operator ==(Object other) =>
      other is CommandRecord &&
      other.id == id &&
      other.cwd == cwd &&
      other.startedAt == startedAt &&
      other.finishedAt == finishedAt &&
      other.status == status &&
      other.stdin == stdin &&
      _sameArgv(other.argv, argv);

  @override
  int get hashCode => Object.hash(
    id,
    Object.hashAll(argv),
    cwd,
    startedAt,
    finishedAt,
    status,
    stdin,
  );

  @override
  String toString() => 'CommandRecord($commandLine → $statusText)';

  static bool _sameArgv(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Format a duration the same way everywhere it is shown.
///
/// Lives here with the record it formats (Swift keeps it in CommandTiming.swift), because
/// [CommandRecord.durationText] is its first caller and importing the timing roll-up for a
/// string formatter would invert the dependency: the timing panel is built FROM records. The
/// abctl copy had the identical body as `CommandRecord.shortDuration`, for the identical
/// reason ("kept next to its heaviest user so a timing roll-up in the models layer calls it
/// instead of re-spelling the format and drifting from the command log"); the two collapse
/// into this one function, under the name the timing tests already call.
abstract final class DurationText {
  static String short(Duration duration) {
    final seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds >= 60) {
      final whole = seconds.round();
      return '${whole ~/ 60}m ${whole % 60}s';
    }
    return '${seconds.toStringAsFixed(1)}s';
  }
}
