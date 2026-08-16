// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:abgui/src/models/command_record.dart';

/// Turns argv into text for humans. This is the ONE place that conversion happens — the live
/// preview in a sheet, the `$ …` lines in the GitOps progress logs, the Command Log page and
/// every copy button all route through here, so what the user is shown BEFORE a run and what
/// is recorded after it cannot drift apart.
///
/// **Why it lives in `abctl/` while the record it renders lives in `models/`.** The record is
/// data (Swift: `Models/CommandRecord.swift`); this is knowledge about the CLI — how a shell
/// quotes a token, that `-f -` reads stdin, that a tree-relative verb needs a `cd` first — and
/// that belongs beside the runner that spends it. The two files import each other, which Dart
/// permits and which is deliberate rather than an oversight: redaction has to run inside
/// [CommandRecord]'s constructor (that is the whole invariant — a record holding a secret
/// cannot be constructed), and `commandLine`/`script` have to render from the record's own
/// fields. Splitting the pair any other way would mean a second copy of the redactor, which is
/// precisely the drift this class exists to prevent.
abstract final class CommandFormatter {
  /// Flags whose VALUE is a credential. Adding a future secret-bearing flag is one line here.
  /// Deliberately NOT redacted: `--client-id` and `--context` (identifiers the UI already
  /// displays) and `--key` (a filesystem path, not key material) — hiding those would make a
  /// copied command unusable without protecting anything.
  static const Set<String> redactedFlags = <String>{'--vpp-token'};
  static const String redactionPlaceholder = '****';

  /// Replace the value of every credential-bearing flag. Handles both `--flag value` and
  /// `--flag=value`, and is idempotent (re-redacting already-redacted argv is a no-op), so it
  /// is safe to apply defensively at display time as well as at record time.
  ///
  /// The result is UNMODIFIABLE (abctl copy; the models copy returned a growable list). A
  /// redacted argv is the only argv a `CommandRecord` ever holds, and a caller that appended
  /// the raw token back onto it would defeat the invariant silently — this makes that throw.
  ///
  /// **Known limit, recorded before it can matter: the scan is positionally blind.** It has no
  /// model of which tokens are flags and which are values, so a token whose literal VALUE is a
  /// redacted flag name — `create config --name --vpp-token`, say — makes the NEXT token render
  /// as `****` while the executed argv keeps it. That is a display artefact in the safe
  /// direction (it hides too much, never too little) and it is unreachable today: `--vpp-token`
  /// is the only entry in [redactedFlags], and the VPP verbs take no free-text argument. Adding
  /// a second flag here — particularly one whose name could plausibly be typed into a name field
  /// — is the point at which this needs an argv-aware redactor rather than a set membership test.
  static List<String> redact(List<String> argv) {
    final out = <String>[];
    var skipNext = false;
    for (final arg in argv) {
      if (skipNext) {
        skipNext = false;
        out.add(redactionPlaceholder);
        continue;
      }
      if (redactedFlags.contains(arg)) {
        out.add(arg);
        skipNext = true; // the NEXT token is the secret
        continue;
      }
      final eq = arg.indexOf('=');
      if (eq >= 0 && redactedFlags.contains(arg.substring(0, eq))) {
        out.add('${arg.substring(0, eq)}=$redactionPlaceholder');
        continue;
      }
      out.add(arg);
    }
    return List.unmodifiable(out);
  }

  /// `abctl <args>` on one line, POSIX-quoted where a token needs it.
  static String line(List<String> argv) =>
      ['abctl', ...redact(argv).map(quote)].join(' ');

  /// The copy-paste form: the `cd` that makes a tree-relative command correct, the command
  /// itself, and — when abgui piped a profile in — a note plus a real path in place of `-f -`.
  static String script({
    required List<String> argv,
    String? cwd,
    CommandStdin stdin = const CommandStdin.none(),
  }) {
    final lines = <String>[];
    if (cwd != null) {
      lines.add('cd ${quote(cwd)}');
    }
    final bytes = stdin.bytes;
    if (bytes == null) {
      lines.add(line(argv));
    } else {
      final file = _profileFileName(argv);
      lines.add(line(_rewriteStdinFlag(argv, file)));
      lines.add(
        '# abgui sent the profile on stdin ($bytes bytes); '
        'export it to $file first.',
      );
    }
    return lines.join('\n');
  }

  /// POSIX single-quoting: leave shell-safe tokens bare so the common case stays readable,
  /// and quote anything else (spaces in a config name, an empty argument, shell metacharacters).
  ///
  /// POSIX even on Windows, where the copied line is meant for the shell an administrator
  /// actually drives abctl from (bash/zsh, or PowerShell — which reads `'…'` as a literal
  /// too). `cmd.exe` is the one shell this is wrong for; quoting for it would break the other
  /// three, and there is only one string to hand out.
  ///
  /// The scan is a character loop (abctl copy) rather than the models copy's
  /// `RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$')`. Same verdict on every input, but an anchored `$`
  /// is the kind of thing that quietly acquires end-of-line semantics, and a token wrongly
  /// judged "safe" here is an unquoted newline in a command someone pastes into a shell.
  static String quote(String s) {
    if (s.isEmpty) return "''";
    for (final unit in s.codeUnits) {
      if (!_shellSafe.contains(String.fromCharCode(unit))) {
        return "'${s.replaceAll("'", r"'\''")}'";
      }
    }
    return s;
  }

  static const String _shellSafe =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-';

  /// Swap the `-f -` (read stdin) pair for a real path, so the copied line runs unattended.
  static List<String> _rewriteStdinFlag(List<String> argv, String file) {
    final out = List<String>.of(argv);
    for (var i = 0; i < out.length - 1; i++) {
      if (out[i] == '-f' && out[i + 1] == '-') {
        out[i + 1] = file;
        break;
      }
    }
    return out;
  }

  /// Derive a plausible on-disk name for a stdin-fed profile from the command's positional
  /// argument (`create config <name> -f -` / `replace config <id> -f -`).
  static String _profileFileName(List<String> argv) {
    final positional =
        argv.length > 2 && (argv[0] == 'create' || argv[0] == 'replace')
        ? argv[2]
        : 'profile';
    final buffer = StringBuffer();
    var lastWasHyphen = false;
    // Unicode-aware on purpose (`\p{L}`/`\p{N}`, not `A-Za-z`), matching Swift's
    // `isLetter || isNumber`: `Wi-Fi Büro` must slug to `Wi-Fi-Büro`, not to a row of hyphens,
    // because the whole point of the name is that the admin recognizes it in the comment the
    // script prints. Iterating RUNES rather than `split('')` is what keeps a character outside
    // the BMP from being torn into two surrogate halves and slugged away.
    for (final rune in positional.runes) {
      final ch = String.fromCharCode(rune);
      if (_slugKeep.hasMatch(ch) || ch == '-' || ch == '_' || ch == '.') {
        buffer.write(ch);
        lastWasHyphen = ch == '-';
      } else if (!lastWasHyphen) {
        buffer.write('-');
        lastWasHyphen = true;
      }
    }
    var slug = _trimHyphens(buffer.toString());
    if (slug.isEmpty) slug = 'profile';
    if (!slug.toLowerCase().endsWith('.mobileconfig')) slug += '.mobileconfig';
    return './$slug';
  }

  static final RegExp _slugKeep = RegExp(r'^[\p{L}\p{N}]$', unicode: true);

  static String _trimHyphens(String s) {
    var start = 0;
    var end = s.length;
    while (start < end && s[start] == '-') {
      start++;
    }
    while (end > start && s[end - 1] == '-') {
      end--;
    }
    return s.substring(start, end);
  }
}
