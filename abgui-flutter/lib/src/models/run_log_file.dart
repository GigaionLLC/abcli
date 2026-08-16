// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

/// One run log on disk, as the Logs screen lists it.
///
/// The identity fields come from the FILENAME, which encodes verb, UTC start and a short run
/// id — so listing fifty logs costs a directory read and no file opens. The outcome and
/// duration come from a bounded read of the file's TAIL, because the writer puts them in a
/// footer: that is what lets the list say "failed" or "plan computed" without loading
/// megabytes of transcript for a row the user may never click.
class RunLogFile {
  final String path;
  final String verb;

  /// Parsed from the filename stamp, which is UTC and therefore comparable across machines.
  final DateTime? startedAt;

  final DateTime modifiedAt;
  final int sizeBytes;

  /// From the footer. Null means the file has no footer — the run was interrupted, or the app
  /// was killed mid-run, which is itself worth showing rather than hiding.
  final String? outcome;
  final String? duration;

  const RunLogFile({
    required this.path,
    required this.verb,
    required this.modifiedAt,
    this.startedAt,
    this.sizeBytes = 0,
    this.outcome,
    this.duration,
  });

  String get id => path;
  String get name => RunLogIndex.lastComponent(path);

  /// A footerless log is an unfinished one: writing the footer is the last thing a finished
  /// run does.
  bool get isUnfinished => outcome == null;

  /// Matches how the app model classifies a failed run, so the list agrees with the sheet that
  /// reported it. Deliberately substring-based: the outcome line is prose written by the
  /// plan/seed/apply paths, not an enum.
  bool get isFailure {
    final text = outcome;
    if (text == null) return false;
    final lowered = text.toLowerCase();
    return lowered.startsWith('failed') || lowered.contains('error');
  }

  String get sizeText {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (sizeBytes >= 1024) return '${sizeBytes ~/ 1024} KB';
    return '$sizeBytes bytes';
  }

  @override
  bool operator ==(Object other) =>
      other is RunLogFile &&
      other.path == path &&
      other.verb == verb &&
      other.startedAt == startedAt &&
      other.modifiedAt == modifiedAt &&
      other.sizeBytes == sizeBytes &&
      other.outcome == outcome &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(
    path,
    verb,
    startedAt,
    modifiedAt,
    sizeBytes,
    outcome,
    duration,
  );

  @override
  String toString() => 'RunLogFile($name → ${outcome ?? 'unfinished'})';
}

/// Reads the run-log directory into [RunLogFile] rows. Pure filesystem — no abctl, no network,
/// no credentials — so the Logs screen works even when the tenant connection is broken, which
/// is exactly when someone needs it.
abstract final class RunLogIndex {
  /// How much of the file's end to read looking for the footer. The footer is ~6 short lines;
  /// this is generous and still bounded, so a 5 MiB transcript costs the same as an empty one.
  static const int footerProbeBytes = 2048;

  /// The verbs that open a log. Kept here with the name PARSER because the two halves have to
  /// agree on the filename shape; when the writer is ported it must consume [isRunLogName]
  /// rather than re-spelling it, or the Logs screen will silently stop listing a new verb —
  /// and the pruner, which deletes what this matches, will stop protecting it.
  static const List<String> verbs = <String>['sync', 'diff', 'seed'];

  static List<RunLogFile> scan(String directory) {
    final List<FileSystemEntity> found;
    try {
      found = Directory(directory).listSync();
    } on FileSystemException {
      return const <RunLogFile>[];
    }
    final out = <RunLogFile>[];
    for (final entity in found) {
      if (entity is! File) continue;
      final name = lastComponent(entity.path);
      if (!isRunLogName(name)) continue;
      FileStat? stat;
      try {
        stat = entity.statSync();
      } on FileSystemException {
        stat = null;
      }
      final footer = readFooter(entity.path);
      out.add(
        RunLogFile(
          path: entity.path,
          verb: verbFromName(name),
          startedAt: startDateFromName(name),
          modifiedAt: stat?.modified ?? DateTime.utc(1, 1, 1),
          sizeBytes: stat?.size ?? 0,
          outcome: footer.outcome,
          duration: footer.duration,
        ),
      );
    }
    // Newest first: the log you want is almost always the one that just ran.
    out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return out;
  }

  /// Only abgui's own files. The log directory is a shared OS location, so a stray file must
  /// not appear as a run — the same rule the pruner follows before DELETING.
  static bool isRunLogName(String name) {
    if (!name.endsWith('.log')) return false;
    final parts = name.substring(0, name.length - 4).split('-');
    if (parts.length != 3 || !verbs.contains(parts[0])) return false;
    final stamp = parts[1];
    if (stamp.length != 16 || !stamp.endsWith('Z')) return false;
    for (var i = 0; i < stamp.length - 1; i++) {
      if (i == 8) {
        if (stamp[i] != 'T') return false;
      } else if (!_isAsciiDigit(stamp.codeUnitAt(i))) {
        return false;
      }
    }
    final hex = parts[2];
    return hex.length == 6 &&
        hex.split('').every((c) => _isLowerHexDigit(c.codeUnitAt(0)));
  }

  /// `diff-20260813T204445Z-b37749.log` → `diff`. The name shape is guaranteed by
  /// [isRunLogName], which every caller here filters on first.
  static String verbFromName(String name) {
    final stem = name.endsWith('.log')
        ? name.substring(0, name.length - 4)
        : name;
    final parts = stem.split('-');
    return parts.isEmpty || parts.first.isEmpty ? 'run' : parts.first;
  }

  /// `…-20260813T204445Z-…` → the instant, in UTC. Null if the stamp doesn't parse, which the
  /// UI then falls back to file mtime for rather than inventing a date.
  static DateTime? startDateFromName(String name) {
    final stem = name.endsWith('.log')
        ? name.substring(0, name.length - 4)
        : name;
    final parts = stem.split('-');
    if (parts.length != 3) return null;
    final stamp = parts[1];
    if (stamp.length != 16) return null;
    int? part(int start, int end) => int.tryParse(stamp.substring(start, end));
    final year = part(0, 4);
    final month = part(4, 6);
    final day = part(6, 8);
    final hour = part(9, 11);
    final minute = part(11, 13);
    final second = part(13, 15);
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    return DateTime.utc(year, month, day, hour, minute, second);
  }

  /// Pull `outcome:` / `duration:` out of the file's tail. Reading only the end is the point:
  /// the list shows the verdict for every log without opening any of them fully.
  static ({String? outcome, String? duration}) readFooter(String path) {
    RandomAccessFile? handle;
    try {
      handle = File(path).openSync();
      final end = handle.lengthSync();
      final start = end > footerProbeBytes ? end - footerProbeBytes : 0;
      handle.setPositionSync(start);
      final bytes = handle.readSync(end - start);
      // `allowMalformed` because the probe window can cut a multi-byte character in half.
      // Swift's decoder answers nil for that and loses the whole footer; a replacement
      // character in one clipped line is a far better trade than a log that reads as
      // unfinished when it is not.
      final text = utf8.decode(bytes, allowMalformed: true);
      String? outcome;
      String? duration;
      // Last occurrence wins: the probe window can clip into transcript text that happens to
      // contain the same words, and the real footer is always last.
      for (final line in text.split('\n')) {
        if (line.startsWith('outcome: ')) {
          outcome = line.substring('outcome: '.length);
        }
        if (line.startsWith('duration: ')) {
          duration = line.substring('duration: '.length);
        }
      }
      return (outcome: outcome, duration: duration);
    } on FileSystemException {
      return (outcome: null, duration: null);
    } finally {
      handle?.closeSync();
    }
  }

  /// Read a whole log for display. Bounded by the writer's own per-file cap, so this cannot be
  /// handed something unbounded; a read failure returns null rather than garbage.
  static String? contents(String path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  /// The filename half of a path, with either separator — Windows hands back `\`, and the
  /// name shape is what everything here parses.
  static String lastComponent(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  static bool _isAsciiDigit(int code) => code >= 0x30 && code <= 0x39;

  static bool _isLowerHexDigit(int code) =>
      _isAsciiDigit(code) || (code >= 0x61 && code <= 0x66);
}
