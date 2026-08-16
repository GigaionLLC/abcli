// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Turns a typed command line into argv, the way a shell would.
///
/// The console hands what you type straight to the same runner seam the buttons use — no shell
/// is involved, so quoting has to be honoured HERE or a configuration named
/// `Corp WiFi.mobileconfig` arrives as two arguments and the command fails for a reason that
/// looks nothing like the cause.
abstract final class CommandLineParser {
  /// Split on whitespace, respecting single and double quotes and backslash escapes. A leading
  /// `abctl` is dropped: people paste whole command lines, and the binary is implied.
  ///
  /// Deliberately NOT a shell: no globbing, no `$VAR`, no pipes or redirection. Those would be
  /// promises this cannot keep — there is no shell behind them — and a `$TOKEN` that silently
  /// expanded would put a secret on argv, which is the one thing this app never does.
  static List<String> tokenize(String line) {
    final out = <String>[];
    final current = StringBuffer();
    String? quote;
    var escaped = false;
    // Distinguishes a real empty argument ("") from no argument at all.
    var started = false;

    for (final ch in line.split('')) {
      if (escaped) {
        current.write(ch);
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        escaped = true;
        started = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else {
          current.write(ch);
        }
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        started = true;
        continue;
      }
      if (_whitespace.hasMatch(ch)) {
        if (started) out.add(current.toString());
        current.clear();
        started = false;
        continue;
      }
      current.write(ch);
      started = true;
    }
    if (started) out.add(current.toString());

    if (out.isNotEmpty && out.first.toLowerCase() == 'abctl') out.removeAt(0);
    return out;
  }

  /// Verbs that change the live tenant. Used only to WARN — the gate itself stays abctl's job,
  /// and this list being wrong must never be what decides whether a write happens.
  static const Set<String> writeVerbs = <String>{
    'create',
    'replace',
    'edit',
    'delete',
    'attach',
    'detach',
    'assign',
    'unassign',
    'apply',
    'sync',
  };

  /// True when the command would write to Apple Business AND carries its own approval. abgui
  /// shows its own confirmation before running one of these, because a typed `--yes` is the
  /// only path in the app that reaches a tenant write without a button having asked first.
  static bool isApprovedTenantWrite(List<String> argv) {
    if (!_isWriteVerb(argv)) return false;
    // `sync` only writes with --apply; a bare `sync` is a dry run.
    if (argv.first.toLowerCase() == 'sync' && !argv.contains('--apply')) {
      return false;
    }
    // `api` is excluded from writeVerbs entirely: its method lives in a flag, and abctl
    // gates any non-GET itself.
    return argv.contains('--yes');
  }

  /// True for a write verb typed WITHOUT approval. Worth saying out loud: abctl will ask on
  /// stdin, the console gives it none, and the command aborts having changed nothing. That is
  /// a safe outcome but a confusing one if you expected it to run.
  static bool isUnapprovedWrite(List<String> argv) {
    if (!_isWriteVerb(argv)) return false;
    if (argv.first.toLowerCase() == 'sync' && !argv.contains('--apply')) {
      return false;
    }
    return !argv.contains('--yes');
  }

  static bool _isWriteVerb(List<String> argv) =>
      argv.isNotEmpty && writeVerbs.contains(argv.first.toLowerCase());

  /// Unicode-aware, to match Swift's `Character.isWhitespace`: a non-breaking space pasted out
  /// of a web page still separates arguments rather than becoming part of one.
  static final RegExp _whitespace = RegExp(r'\s', unicode: true);
}
