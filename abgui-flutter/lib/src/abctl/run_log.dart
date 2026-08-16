// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:abgui/src/models/command_record.dart';

import 'credential_store.dart' show FilePermissions;

/// One run's transcript, on disk. A sync that fails at 2:00 a.m. is worth nothing if the only
/// copy of the evidence is a scroll view the user closes; this writes the same narration to a
/// file the app can hand to a support ticket by path.
///
/// **Location.** Per platform, always a per-user directory, and deliberately NOT inside the
/// user's GitOps workspace: abgui does not own that repo's `.gitignore`, so writing logs there
/// would eventually commit tenant identifiers. See [defaultDirectory].
///
/// **What a log may contain.** Everything abctl prints on stderr plus abgui's own transcript
/// lines. That means TENANT IDENTIFIERS — context/organization names, configuration and
/// blueprint names, device serials, Apple resource ids — and up to a few hundred bytes of
/// Apple's raw error-response body. It does NOT contain credentials: the argv in the header is
/// `CommandRecord`'s redacted form (never the raw args), key material is never on argv in the
/// first place (contexts pass a key *path*), the one verb that prints a bearer token
/// (`auth token --raw`) writes it to stdout and abgui has no client method for it, and profile
/// XML fed on stdin is recorded as a byte count only. Files are locked to the current user for
/// the same reason `CredentialStore`'s are — including the WEAKER Windows guarantee documented
/// at the top of that file, which applies here too.
///
/// **It cannot break a sync.** The public API never throws: [begin] returns null if anything
/// at all goes wrong (no directory, read-only disk, sandbox denial), [line] is
/// fire-and-forget and costs a list append — no syscall on the caller's turn of the event
/// loop, so a 2,000-line run does not spend 2,000 round trips on logging — and a failed write
/// quietly retires the log rather than propagating. Logging is a nice-to-have; applying the
/// plan is not.
///
/// Ported from the Swift `RunLog` actor. Two things the Swift version needed are absent here
/// because Dart has one thread per isolate: the `NSLock` around the hand-off buffer, and the
/// worry about unstructured tasks reaching an actor out of order. Ordering instead comes from
/// the fact that [line] appends synchronously and the drain is a microtask.
class RunLog {
  RunLog._(this._sink, this.path, this.startedAt);

  /// Bumped when the header/footer layout changes, so a parser (or a human) can tell which
  /// shape they are reading.
  static const int schemaVersion = 1;

  // Retention: at most this many files, none older than this, no more than this on disk in
  // total — whichever bites first, oldest deleted first. One file is capped as well, so a
  // pathological run cannot eat the budget by itself.
  static const int maxFiles = 50;
  static const Duration maxAge = Duration(days: 14);
  static const int maxTotalBytes = 20 * 1024 * 1024;
  static const int maxFileBytes = 5 * 1024 * 1024;
  static const String truncationMarker = '[log truncated]\n';

  /// A ceiling on unflushed lines, in case a producer somehow outruns the writer. Dropping the
  /// overflow beats growing without bound inside a process that is mid-sync.
  static const int bufferCap = 20000;

  /// The outcome headline budget in the footer. Long enough for a real Apple error sentence,
  /// short enough that a `tail` of the file stays readable.
  static const int outcomeLimit = 400;

  /// Where this run is being written. Shown and copied by the UI.
  final String path;

  final DateTime startedAt;

  IOSink? _sink;
  final List<String> _pending = <String>[];
  bool _drainScheduled = false;
  int _bytesWritten = 0;
  int _linesWritten = 0;
  int _droppedLines = 0;
  bool _truncated = false;
  bool _closed = false;

  /// The default log directory for this platform:
  ///
  ///  * macOS — `~/Library/Logs/abgui`, the platform convention (Console.app lists it), as in
  ///    the Swift app.
  ///  * Windows — `%LOCALAPPDATA%\abgui\logs`. Local rather than roaming: these files carry
  ///    tenant identifiers and can reach 20 MB, neither of which belongs on a profile share.
  ///  * Linux — `$XDG_STATE_HOME/abgui/logs`, defaulting to `~/.local/state/abgui/logs`.
  ///    `state`, not `cache`: a log the user may attach to a support ticket must survive a
  ///    cache sweep, and it is not configuration either.
  static String defaultDirectory({
    Map<String, String>? environment,
    bool? isWindows,
    bool? isMacOS,
  }) {
    final env = environment ?? Platform.environment;
    final windows = isWindows ?? Platform.isWindows;
    final mac = isMacOS ?? Platform.isMacOS;
    if (windows) {
      final base = _firstNonEmpty([
        env['LOCALAPPDATA'],
        _join([env['USERPROFILE'], 'AppData', 'Local'], r'\'),
      ]);
      return _join([base, 'abgui', 'logs'], r'\');
    }
    final home = _firstNonEmpty([env['HOME'], '.']);
    if (mac) return _join([home, 'Library', 'Logs', 'abgui'], '/');
    final stateHome = _firstNonEmpty([
      env['XDG_STATE_HOME'],
      _join([home, '.local', 'state'], '/'),
    ]);
    return _join([stateHome, 'abgui', 'logs'], '/');
  }

  /// Open a log for this run, or return null if it cannot be created. `null` is a perfectly
  /// normal outcome — callers hold a `RunLog?` and use `?.`, so a machine that cannot write
  /// logs simply runs without them.
  ///
  /// Async where Swift was actor-isolated, and for the same reason: tightening permissions
  /// costs a subprocess on every platform (Dart's `File` has no chmod), and doing that
  /// synchronously would stall the frame that starts the sync.
  static Future<RunLog?> begin(
    RunLogHeader header, {
    DateTime? at,
    String? runId,
    String? directory,
  }) async {
    final started = at ?? DateTime.now();
    final dir = directory ?? defaultDirectory();
    final separator = dir.contains(r'\') && !dir.contains('/') ? r'\' : '/';
    final file = File(
      _join([
        dir,
        fileName(
          verb: header.verb,
          started: started,
          runId: runId ?? CommandRecord.newId(),
        ),
      ], separator),
    );
    try {
      await Directory(dir).create(recursive: true);
      // A directory abgui created earlier (or another tool, or a looser umask) keeps whatever
      // mode it has, so the restriction is asserted unconditionally — cheap, idempotent, and
      // it is what makes the promise above true. The LISTING itself is sensitive: it
      // enumerates which tenant operations ran and when.
      await FilePermissions.restrictDirectory(dir);
      // Create, restrict, and only then open for writing. Dart cannot create-with-mode the way
      // `FileManager.createFile(attributes:)` could, so there is a brief instant where the file
      // carries the process umask's mode; it is unreachable by another user for that instant
      // because the directory above it is already owner-only.
      await file.create();
      await FilePermissions.restrictFile(file.path);
      final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      final log = RunLog._(sink, file.path, started);
      // The sink reports write failures asynchronously; a full disk mid-sync must retire the
      // log, not surface as an unhandled error inside whatever was being applied.
      unawaited(sink.done.then((_) {}, onError: (Object _) => log._retire()));
      log._write(headerText(header, startedAt: started));
      return log;
    } catch (_) {
      return null;
    }
  }

  /// Record one line. Fire-and-forget by contract: no await, no throw, no result.
  void line(String text) {
    if (_closed) return;
    if (_pending.length < bufferCap) {
      _pending.add(stamped(text, DateTime.now().difference(startedAt)));
    }
    if (_drainScheduled) return;
    _drainScheduled = true;
    // At most one drain is ever in flight, which is what keeps a 2,000-line run from
    // scheduling 2,000 microtasks.
    scheduleMicrotask(_flush);
  }

  /// Prefix a transcript line with seconds since the run started, so the file answers "where
  /// did the time go INSIDE this command?" and not merely "how long did the whole thing take".
  /// A total duration tells you a run was slow; these tell you which step was.
  ///
  /// The stamp is taken when the line reaches this log, which is up to one progress-flush tick
  /// after abctl printed it. That is a bounded, uniform skew — fine for finding the slow step,
  /// not a claim of sub-100ms precision.
  static String stamped(String text, Duration elapsed) {
    final seconds = elapsed.isNegative
        ? 0.0
        : elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    return '[${seconds.toStringAsFixed(3).padLeft(7)}s] $text';
  }

  /// Write the outcome footer and close. Safe to call twice; safe to never call (the file then
  /// simply has no footer, which is itself the signal that the app died mid-run).
  Future<void> finish({required String outcome, DateTime? at}) async {
    if (_closed) return;
    _flush();
    _write(
      footerText(
        outcome: outcome,
        startedAt: startedAt,
        finishedAt: at ?? DateTime.now(),
        lines: _linesWritten,
        dropped: _droppedLines,
        truncated: _truncated,
      ),
    );
    final sink = _sink;
    _closed = true;
    _sink = null;
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {
      // The transcript is already as complete as it is going to get.
    }
    // Pruning touches the whole directory, so it happens off this run's critical path AND off
    // this ISOLATE.
    //
    // `Future<void>(…)` — which is what this used to be — defers to a later turn of the SAME
    // event loop, so the `listSync()`, the ~50 `statSync()`s and the `deleteSync()`s below all
    // ran on the platform thread, at the end of every diff, seed and `sync --apply`: precisely
    // the frame that paints the apply verdict. On a network home directory or with an
    // on-access AV scanner that is a visible stall on the one frame the operator is waiting
    // for. `archive_screen.dart` and `archived_file_dialog.dart` already walk directories
    // through `Isolate.run` for exactly this reason.
    //
    // The closure is deliberately trivial — it captures two `String`s and calls a STATIC method
    // — because `Isolate.run` sends the closure, and one that captured `this` would drag the
    // open `IOSink` along with it and throw before reading a directory. Best-effort throughout:
    // a failure to prune is not a failure of anything, and an isolate that will not spawn must
    // not turn a completed run into a failed one.
    final keep = path;
    final directory = _dirname(keep);
    unawaited(
      Isolate.run(
        () => prune(excluding: keep, directory: directory),
      ).catchError((Object _) {}),
    );
  }

  /// Drain the buffer into the file. Deliberately has NO await in its body, so two drains can
  /// never interleave and reorder the transcript.
  void _flush() {
    _drainScheduled = false;
    if (_pending.isEmpty || _closed) {
      _pending.clear(); // drained regardless, so memory is freed
      return;
    }
    final pending = List<String>.of(_pending);
    _pending.clear();
    final chunk = StringBuffer();
    var chunkBytes = 0;
    for (final text in pending) {
      if (_truncated) {
        _droppedLines++;
        continue;
      }
      final size = utf8.encode(text).length;
      if (_bytesWritten + chunkBytes + size + 1 > maxFileBytes) {
        chunk.write(truncationMarker);
        chunkBytes += truncationMarker.length;
        _truncated = true;
        _droppedLines++;
        continue;
      }
      chunk
        ..write(text)
        ..write('\n');
      chunkBytes += size + 1;
      _linesWritten++;
    }
    _write(chunk.toString());
  }

  /// The one write path. A failed write retires the log instead of throwing: there is no caller
  /// who could do anything useful with the error, and a sync must not care.
  void _write(String text) {
    final sink = _sink;
    if (_closed || sink == null || text.isEmpty) return;
    final data = utf8.encode(text);
    try {
      sink.add(data);
      _bytesWritten += data.length;
    } catch (_) {
      _retire();
    }
  }

  void _retire() {
    final sink = _sink;
    _closed = true;
    _sink = null;
    unawaited(sink?.close().catchError((Object _) {}) ?? Future<void>.value());
  }

  // MARK: text (pure + static, so the layout is testable without a filesystem)

  static String headerText(RunLogHeader header, {required DateTime startedAt}) {
    // Blank means "abctl resolves its own current context" — say that, rather than printing an
    // empty field a reader would have to guess about.
    final contextName = header.context == null || header.context!.isEmpty
        ? '(abctl default)'
        : header.context!;
    final out = <String>[
      '# abgui run log',
      'schema: $schemaVersion',
      'verb: ${header.verb.name}',
      'started: ${isoUtc(startedAt)}',
      'abgui: ${header.abguiVersion ?? 'unknown (version not supplied)'}',
      'abctl: ${abctlDescription(version: header.abctlVersion, commit: header.abctlCommit)}',
      'os: ${header.os ?? currentOs()}',
      'context: $contextName',
      'workspace: ${header.workspace ?? '(none)'}',
      'command: ${header.command}',
    ];
    final bytes = header.stdin.bytes;
    if (bytes != null) {
      // The SIZE, never the content — a profile can carry anything the admin put in it.
      out.add('stdin: profile on stdin ($bytes bytes)');
    }
    out.addAll([
      '#',
      '# Everything below is abctl\'s stderr plus abgui\'s own transcript lines. It can',
      '# contain tenant identifiers (organization/context names, configuration and',
      '# blueprint names, device serials, Apple resource ids) and Apple\'s raw error',
      '# response body. It contains no credentials: the command above is the redacted',
      '# form, and anything piped in is recorded as a byte count only.',
      '# The outcome and duration are written as a footer at the END of this file.',
      '---',
      '',
    ]);
    return out.join('\n');
  }

  static String footerText({
    required String outcome,
    required DateTime startedAt,
    required DateTime finishedAt,
    required int lines,
    required int dropped,
    required bool truncated,
  }) {
    final out = <String>[
      '',
      '---',
      'finished: ${isoUtc(finishedAt)}',
      'duration: ${durationText(finishedAt.difference(startedAt))}',
      'outcome: ${shorten(outcome, limit: outcomeLimit)}',
      'lines: $lines',
    ];
    if (truncated || dropped > 0) {
      out.add(
        'dropped: $dropped line(s) — this run exceeded the '
        '${maxFileBytes ~/ (1024 * 1024)} MiB per-file cap',
      );
    }
    out.add('');
    return out.join('\n');
  }

  /// Which machine wrote this. Cross-platform where the Swift original could only ever say
  /// "macOS", and worth a line: half of "it works on my machine" is which machine.
  static String currentOs() =>
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

  static String abctlDescription({String? version, String? commit}) {
    if (version == null || version.isEmpty) {
      return 'unknown (not connected yet)';
    }
    if (commit == null || commit.isEmpty) return version;
    return '$version ($commit)';
  }

  static String durationText(Duration duration) {
    final seconds = duration.isNegative
        ? 0.0
        : duration.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds >= 60) {
      final whole = seconds.round();
      return '${whole ~/ 60}m ${whole % 60}s';
    }
    return '${seconds.toStringAsFixed(1)}s';
  }

  /// One line, whitespace collapsed (Apple's raw body arrives with embedded newlines) and cut
  /// at a word boundary. Truncation is safe here ONLY because the transcript above the footer
  /// keeps the full text.
  static String shorten(String text, {required int limit}) {
    final flat = text
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .join(' ');
    if (flat.length <= limit) return flat;
    final head = flat.substring(0, limit);
    final space = head.lastIndexOf(' ');
    if (space > limit ~/ 2) {
      return '${head.substring(0, space).trimRight()}…';
    }
    return '${head.trimRight()}…';
  }

  // MARK: naming + retention

  static String fileName({
    required RunLogVerb verb,
    required DateTime started,
    required String runId,
  }) => '${verb.name}-${compactUtc(started)}-${shortId(runId)}.log';

  /// First 6 hex of the run's id: enough to tell apart two runs that started in the same
  /// second, short enough to read out over a support call.
  static String shortId(String id) {
    final hex = id.replaceAll('-', '').toLowerCase();
    return hex.length <= 6 ? hex.padRight(6, '0') : hex.substring(0, 6);
  }

  /// `20260725T143005Z` — sorts lexicographically, is filename-safe, and is UTC so logs from
  /// two machines (or across a DST change) still line up.
  static String compactUtc(DateTime date) {
    final d = date.toUtc();
    return '${_pad(d.year, 4)}${_pad(d.month, 2)}${_pad(d.day, 2)}T'
        '${_pad(d.hour, 2)}${_pad(d.minute, 2)}${_pad(d.second, 2)}Z';
  }

  static String isoUtc(DateTime date) {
    final d = date.toUtc();
    return '${_pad(d.year, 4)}-${_pad(d.month, 2)}-${_pad(d.day, 2)}T'
        '${_pad(d.hour, 2)}:${_pad(d.minute, 2)}:${_pad(d.second, 2)}Z';
  }

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');

  /// Enforce the retention budget, oldest first. Best-effort and completely silent.
  static void prune({String? excluding, DateTime? now, String? directory}) {
    final dir = Directory(directory ?? defaultDirectory());
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync();
    } catch (_) {
      return;
    }
    final files = <_LogFile>[];
    for (final entry in entries) {
      if (entry is! File) continue;
      final name = _basename(entry.path);
      if (name.startsWith('.')) continue; // skip hidden, as the Swift scan did
      if (!isRunLogName(name)) continue;
      try {
        final stat = entry.statSync();
        files.add(_LogFile(entry.path, stat.modified, stat.size));
      } catch (_) {
        continue;
      }
    }
    // Newest first, so "keep the newest N" is a prefix.
    files.sort((a, b) => b.modified.compareTo(a.modified));
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    var running = 0;
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      running += file.size;
      final overCount = index >= maxFiles;
      final tooOld = file.modified.isBefore(cutoff);
      final overBudget = running > maxTotalBytes;
      if (!overCount && !tooOld && !overBudget) continue;
      if (excluding != null && file.path == excluding) {
        continue; // never the run that just wrote
      }
      try {
        File(file.path).deleteSync();
      } catch (_) {
        // Someone else's lock, a read-only volume — not ours to insist.
      }
    }
  }

  /// Matches ONLY the `<verb>-<UTC timestamp>-<6 hex>.log` names this type writes. The pruner
  /// DELETES, so it recognizes abgui's own shape and nothing else — whatever else a user or
  /// another tool parked in that folder is not ours to remove.
  static bool isRunLogName(String name) {
    if (!name.endsWith('.log')) return false;
    final parts = name.substring(0, name.length - 4).split('-');
    if (parts.length != 3) return false;
    if (!RunLogVerb.values.any((v) => v.name == parts[0])) return false;
    final stamp = parts[1];
    if (stamp.length != 16 || !stamp.endsWith('Z')) return false;
    for (var offset = 0; offset < stamp.length - 1; offset++) {
      final ch = stamp[offset];
      if (offset == 8) {
        if (ch != 'T') return false;
      } else if (!_isAsciiDigit(ch)) {
        return false;
      }
    }
    final hex = parts[2];
    if (hex.length != 6) return false;
    return hex.split('').every(_isLowerHex);
  }

  static bool _isAsciiDigit(String ch) {
    final code = ch.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  static bool _isLowerHex(String ch) {
    final code = ch.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66);
  }

  static String _basename(String path) {
    var cut = path.lastIndexOf('/');
    final alt = path.lastIndexOf(r'\');
    if (alt > cut) cut = alt;
    return cut < 0 ? path : path.substring(cut + 1);
  }

  static String _dirname(String path) {
    var cut = path.lastIndexOf('/');
    final alt = path.lastIndexOf(r'\');
    if (alt > cut) cut = alt;
    return cut <= 0 ? path : path.substring(0, cut);
  }

  static String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      if (value != null && value.isNotEmpty) return value;
    }
    return '.';
  }

  static String _join(List<String?> parts, String separator) {
    final kept = <String>[];
    for (final part in parts) {
      if (part == null || part.isEmpty) return '';
      kept.add(
        part.endsWith(separator) ? part.substring(0, part.length - 1) : part,
      );
    }
    return kept.join(separator);
  }
}

/// The abctl operations abgui narrates. The name is BOTH the filename prefix and the pruner's
/// match token, so adding a verb is one case here and nothing else.
///
/// Only verbs that actually OPEN a log belong here: the pruner deletes what
/// [RunLog.isRunLogName] matches, and a case nothing writes has it claiming filenames on
/// behalf of a file that never exists. `validate` is deliberately absent — it runs a silent
/// client (no stderr narration is streamed anywhere), so its log would be a header and a
/// footer around nothing, and opening one would repoint "the last run log" away from the sync
/// whose failure is still being reported. Add the case together with the begin/finish calls
/// and a narrating client, never before.
enum RunLogVerb { sync, diff, seed }

/// The self-describing header. Everything needed to reproduce the run, supplied by the caller
/// because only the app layer knows the connection and the workspace.
class RunLogHeader {
  const RunLogHeader({
    required this.verb,
    required this.command,
    this.workspace,
    this.context,
    this.abctlVersion,
    this.abctlCommit,
    this.abguiVersion,
    this.os,
    this.stdin = const CommandStdin.none(),
  });

  final RunLogVerb verb;

  /// The REDACTED command line — `CommandRecord.commandLine`, never raw argv. The type is
  /// `String` precisely so a caller cannot hand this an unredacted `List<String>`.
  final String command;

  final String? workspace;
  final String? context;
  final String? abctlVersion;
  final String? abctlCommit;

  /// abgui's own version. Passed IN rather than read here: the app gets it from a Flutter
  /// plugin, and this layer stays free of plugin (and therefore binding) dependencies so it
  /// can be exercised by a plain unit test.
  final String? abguiVersion;

  /// Override for the OS description, for tests. Defaults to the running platform.
  final String? os;

  /// Only the SIZE of anything piped in; content is never written.
  final CommandStdin stdin;
}

class _LogFile {
  _LogFile(this.path, this.modified, this.size);

  final String path;
  final DateTime modified;
  final int size;
}
