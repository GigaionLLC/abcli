// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'apply_result.dart';

/// What kind of failure this is — the shape of the fix, not the shape of the message.
/// A view can pick an icon or an explanation from this; nothing branches on the text.
enum SyncFailureKind {
  /// abctl ran the plan and Apple (or the tree) rejected individual items. The
  /// authoritative per-item detail came back on stdout as `status:"error"` rows.
  itemsFailed('itemsFailed'),

  /// abctl never got as far as applying — bad credentials, no `gitops/` tree, an Apple
  /// 403 while building the plan. stdout is empty; stderr is all we have.
  aborted('aborted'),

  /// abgui's own watchdog stopped the child (not an abctl exit code).
  timedOut('timedOut'),

  /// The user cancelled. Not a fault, but the tenant is in a half-applied state, so it
  /// is still reported rather than silently swallowed.
  cancelled('cancelled'),

  /// abctl exited 0 but its stdout did not decode — a version skew between the app and
  /// the embedded CLI.
  unreadable('unreadable'),

  /// Every applied item reported `done` and abctl STILL exited non-zero. Today that means
  /// post-apply verification re-read the writes and found Apple had not persisted them
  /// (`internal/cli/phase1.go` → `finishApply`); the verdict is on stderr, not in the rows.
  exitedNonZero('exitedNonZero'),

  /// A token this build does not know. The Swift enum has no such case — it is never
  /// decoded from a wire document, it is constructed — but [fromWire] exists so a kind
  /// restored from a persisted failure (or written by a newer build) degrades to "we know
  /// it failed, we can't classify it" instead of throwing away the headline with it.
  unknown('unknown');

  const SyncFailureKind(this.wire);

  /// The Swift `rawValue`, which is part of `SyncFailure.id`.
  final String wire;

  static SyncFailureKind fromWire(String value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return unknown;
  }
}

/// Why a sync did not do what the administrator asked — reduced to ONE line they can act on,
/// with the complete text kept alongside it.
///
/// The bug this type exists to kill: abgui used to hand the view the raw error description,
/// which for a failed `sync --apply` is abctl's WHOLE stderr — a hundred lines of "building
/// plan: …" narration with the actual cause buried somewhere inside (or, when abctl exits via
/// `cli.ExitError`, not present at all, because `cmd/abctl/main.go` exits SILENTLY for that
/// case). The user's complaint was exactly that: they had to read the log blob to find out
/// whether the sync even failed.
///
/// So the contract here is *ranking, never discarding*: [headline] is the best short summary
/// this code can justify, and [details] is everything it was derived from. Every rule below
/// degrades toward showing more, because losing the cause is the failure mode we are fixing.
class SyncFailure {
  final SyncFailureKind kind;

  /// One line, whitespace-collapsed and truncated. Safe to put in a title or a banner.
  final String headline;

  /// Everything the headline was derived from, verbatim and untruncated. Never empty when
  /// there was anything at all to show.
  final String details;

  const SyncFailure({
    required this.kind,
    required this.headline,
    this.details = '',
  });

  /// Content-derived so an unchanged failure keeps its identity across re-renders (and two
  /// genuinely different failures never collide in a sheet keyed by id).
  String get id => '${kind.wire}|$headline|${details.length}';

  /// The one blob a "Copy error" button should put on the clipboard: the summary the user is
  /// looking at, then the evidence under it. (Copying the *run log* is a separate, bigger
  /// thing — see the run-log index.)
  String get copyableText =>
      details.isEmpty ? headline : '$headline\n\n$details';

  // MARK: the three ways a sync fails — items rejected, a non-zero exit despite clean
  // items (post-apply verification), and an abort with no result document at all.

  /// The COMMON case now that the client decodes before it checks the exit code: abctl applied
  /// the plan and some items came back `status:"error"`, each with a detail naming what Apple
  /// refused. Returns null ONLY for a run that both reported every item done AND exited 0 —
  /// this is the caller's whole pass/fail test, so there is no second condition that could
  /// disagree with it.
  static SyncFailure? fromApplyResult(
    ApplyResult applyResult, {
    int exitCode = 0,
    String stderr = '',
    List<String> transcript = const <String>[],
  }) {
    final failed = applyResult.rows.where((r) => r.failed).toList();
    if (failed.isEmpty) {
      // The counters and the rows are incremented together by the reconcile engine, so they
      // cannot normally disagree — but if a future abctl reports errors without rows, "no
      // rows" must not be read as "clean".
      if (applyResult.totalErrors > 0) {
        return SyncFailure(
          kind: SyncFailureKind.itemsFailed,
          headline:
              'abctl reported ${applyResult.totalErrors} error(s) '
              'without saying which items failed.',
          details:
              'writes: ${applyResult.totalWrites}, '
              'errors: ${applyResult.totalErrors}, '
              'skipped: ${applyResult.totalSkipped}',
        );
      }
      if (exitCode == 0) return null;
      return fromNonZeroExit(
        code: exitCode,
        stderr: stderr,
        transcript: transcript,
      );
    }
    final first = _describe(failed[0]);
    final headline = failed.length == 1
        ? '1 change failed — $first'
        : '${failed.length} of ${applyResult.rows.length} changes failed — '
              'first: $first';
    // A run can fail items AND fail the read-back; the rows are the headline, but the verdict
    // lines are appended so the second problem isn't silently outranked.
    var details = failed.map(_describe).join('\n');
    final verdicts = verdictLines(stderr);
    if (verdicts.isNotEmpty) details += '\n\n${verdicts.join('\n')}';
    return SyncFailure(
      kind: SyncFailureKind.itemsFailed,
      headline: shorten(headline),
      details: details,
    );
  }

  /// abctl applied everything it was asked to, said every item was `done`, and STILL exited
  /// non-zero. Today that is post-apply verification: it re-reads the configs it just wrote and
  /// fails the run when Apple's stored bytes don't match git (Apple answers `2xx` to a PATCH it
  /// then silently drops). The verdict is only on stderr, so it has to be mined out — and the
  /// SUMMARY line of that report starts with the same `post-apply verification: ` prefix as the
  /// progress narration, which is why the explicit `FAILED` lines are looked at first.
  static SyncFailure fromNonZeroExit({
    required int code,
    required String stderr,
    List<String> transcript = const <String>[],
  }) {
    final verdicts = verdictLines(stderr);
    final String headline;
    if (verdicts.length > 1) {
      headline = shorten('${verdicts.length} checks failed — ${verdicts[0]}');
    } else if (verdicts.isNotEmpty) {
      headline = shorten(verdicts.first);
    } else {
      headline =
          extractHeadline(stderr) ??
          'abctl applied the plan but exited $code — the tenant may not match '
              'git.';
    }
    return SyncFailure(
      kind: SyncFailureKind.exitedNonZero,
      headline: headline,
      details: _fallbackDetails(stderr, transcript),
    );
  }

  /// Lines where abctl states a VERDICT rather than progress. `post-apply verification FAILED:`
  /// is the wording `internal/cli/phase1.go` prints (and that CI greps for), so the marker is
  /// the uppercase word rather than the prefix.
  static const String verdictMarker = 'FAILED';

  static List<String> verdictLines(String stderr) => _significantLines(
    stderr,
  ).where((l) => l.contains(verdictMarker)).toList();

  // MARK: the ABORT family.
  //
  // Port note: Swift has one `from(error:)` that switches over `AbctlError`, which is a Backend
  // type this model layer does not (and should not) depend on. The switch is therefore split
  // into one factory per case, taking the same inputs the associated values carried. The
  // classification rules — which kind, which headline, what lands in `details` — are unchanged.

  /// `AbctlError.cli` (exit 1): abctl exited without producing a result document, so the only
  /// evidence is stderr (plus, if that is empty too, whatever abgui already narrated).
  /// [transcript] is the apply progress log — used ONLY as a last resort, since it otherwise
  /// just repeats the same stderr lines back with abgui's own `$ …` lines mixed in.
  static SyncFailure fromAbort({
    required String stderr,
    List<String> transcript = const <String>[],
  }) {
    final text = stderr.trim();
    final source = text.isEmpty ? transcript.join('\n') : text;
    return SyncFailure(
      kind: SyncFailureKind.aborted,
      headline: extractHeadline(source) ?? synthesizedHeadline(source),
      details: _fallbackDetails(text, transcript),
    );
  }

  /// `AbctlError.usage`: a non-0/non-1/non-3 exit means abgui built argv abctl did not
  /// understand. Still mine stderr (it usually names the bad flag), but say whose bug it is.
  static SyncFailure fromUsageRejection({
    required String stderr,
    List<String> transcript = const <String>[],
  }) {
    final failure = fromAbort(stderr: stderr, transcript: transcript);
    return SyncFailure(
      kind: SyncFailureKind.aborted,
      headline: 'abctl rejected the command abgui built — ${failure.headline}',
      details: failure.details,
    );
  }

  /// `AbctlError.timedOut`: the long "here is what a timeout usually means" paragraph is the
  /// DETAIL; the headline just has to say the run was stopped and after how long.
  static SyncFailure fromTimeout({
    required int seconds,
    String description = '',
    List<String> transcript = const <String>[],
  }) => SyncFailure(
    kind: SyncFailureKind.timedOut,
    headline: 'abctl ran for ${seconds}s without finishing and was stopped.',
    details: _fallbackDetails(description, transcript),
  );

  /// `AbctlError.decode`: exit 0, undecodable stdout.
  static SyncFailure fromDecodeFailure({
    String description = '',
    List<String> transcript = const <String>[],
  }) => SyncFailure(
    kind: SyncFailureKind.unreadable,
    headline:
        'abctl finished, but abgui could not read its result — the '
        'app and the embedded CLI may not match.',
    details: _fallbackDetails(description, transcript),
  );

  /// `AbctlError.changesPending`: exit 3 is a dry-run signal; reaching it from `--apply` means
  /// the flags were wrong.
  static SyncFailure fromChangesPending({
    String description = '',
    List<String> transcript = const <String>[],
  }) => SyncFailure(
    kind: SyncFailureKind.aborted,
    headline:
        'abctl reported changes pending (exit 3) instead of applying '
        'them.',
    details: _fallbackDetails(description, transcript),
  );

  /// The user cancelled.
  static SyncFailure fromCancellation({
    List<String> transcript = const <String>[],
  }) => SyncFailure(
    kind: SyncFailureKind.cancelled,
    headline: 'Sync was cancelled before it finished.',
    details: _fallbackDetails('', transcript),
  );

  /// Anything else (a spawn failure, a platform error) already carries a short, human message —
  /// there is no stderr to mine, so use it as-is.
  static SyncFailure fromError(
    String message, {
    List<String> transcript = const <String>[],
  }) => SyncFailure(
    kind: SyncFailureKind.aborted,
    headline: shorten(message.isEmpty ? 'Sync failed.' : message),
    details: _fallbackDetails(message, transcript),
  );

  // MARK: the extractor — PURE, so the rule can be tested against real captured stderr
  // without a process, a tenant or a UI.

  /// `cmd/abctl/main.go` prints `Error: <err>` to stderr for a plain error and exits SILENTLY
  /// for a `cli.ExitError` — so a marked line is NOT guaranteed and the rules have to fall
  /// through:
  ///
  /// 1. the LAST `Error: …` line (the outermost wrap, i.e. the most contextual sentence);
  /// 2. else the last line that is not abctl's progress narration (an unmarked abort such as
  ///    `aborted — no changes applied.` lands here);
  /// 3. else null — the caller synthesizes one, and [details] still carries everything.
  ///
  /// Returns a condensed, truncated single line. An `ab.APIError` can be ~500 characters of
  /// Apple's raw response body, which is why nothing here is used untruncated — and why the
  /// untruncated text is always kept in [details].
  static String? extractHeadline(String stderr) {
    final lines = _significantLines(stderr);
    if (lines.isEmpty) return null;
    for (final line in lines.reversed) {
      if (line.startsWith(errorMarker)) {
        final body = line.substring(errorMarker.length).trim();
        if (body.isNotEmpty) return shorten(body);
        break;
      }
    }
    for (final line in lines.reversed) {
      if (!isNarration(line)) return shorten(line);
    }
    return null;
  }

  /// Rule 3: everything abctl printed was progress narration, so name WHERE it stopped rather
  /// than inventing a cause. Showing the last thing that happened beats a generic sentence,
  /// and the full text is one scroll away regardless.
  static String synthesizedHeadline(String stderr) {
    final lines = _significantLines(stderr);
    if (lines.isEmpty) {
      return 'abctl stopped without applying the plan and printed no error.';
    }
    return shorten('abctl stopped during: ${lines.last}');
  }

  /// abctl's progress narration, by the prefixes it actually emits (`internal/cli/phase1.go`,
  /// `internal/reconcile/apply.go` + `blueprint.go`, `internal/ab/client.go`). These lines
  /// describe what abctl was DOING, never what went wrong, so they are never the headline.
  ///
  /// Deliberately a conservative allow-list of *verified* prefixes: a line wrongly classified
  /// as narration is a hidden cause, which is the bug being fixed here, whereas a line wrongly
  /// kept just makes the headline less pretty.
  static const List<String> narrationPrefixes = <String>[
    'building plan: ',
    'post-apply verification: ',
    'applying config ',
    'applying blueprint ',
    'creating configuration in ABM: ',
    'creating blueprint in ABM: ',
    'deleting configuration from ABM: ',
    // The apply's own confirming read-back (`reconcile.push`) — narration, not a verdict.
    // Without it, a run that aborts during the read-back surfaces "verifying the stored
    // configuration in ABM: X" to the user as the CAUSE of the failure.
    'verifying the stored configuration in ABM: ',
    'attaching ',
    'detaching ',
    'archiving ',
    'patching ',
    'fetching ',
    'requesting ',
    'reusing cached ',
    'read CUSTOM_SETTING ',
    'writing live ',
    'removing git ',
    r'$ abctl ', // abgui's own transcript lines, when the transcript is the last resort
    '→ ',
  ];

  static bool isNarration(String line) =>
      narrationPrefixes.any(line.startsWith);

  /// The marker `main.go` prints for a non-`ExitError` failure.
  static const String errorMarker = 'Error:';

  /// The headline budget. Long enough for a real Apple error sentence, short enough that a
  /// banner stays one or two lines.
  static const int headlineLimit = 180;

  // MARK: text plumbing

  static List<String> _significantLines(String text) => text
      .split(_newline)
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  /// One line, whitespace collapsed (Apple's raw body arrives with embedded newlines) and cut
  /// at a word boundary. Truncation is safe here ONLY because [details] keeps the full text.
  static String shorten(String text, {int limit = headlineLimit}) {
    final flat = text.split(_whitespace).where((w) => w.isNotEmpty).join(' ');
    if (flat.length <= limit) return flat;
    final head = flat.substring(0, limit);
    final space = head.lastIndexOf(' ');
    if (space > limit ~/ 2) return '${head.substring(0, space).trim()}…';
    return '${head.trim()}…';
  }

  /// [details] is the authoritative text; the narrated transcript is only substituted when
  /// there is no authoritative text at all, because it otherwise duplicates the same stderr
  /// the view is already showing in the progress log.
  static String _fallbackDetails(String text, List<String> transcript) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return transcript.join('\n');
  }

  /// One failed apply row as a line: `update-abm WiFi-Corp.mobileconfig: 403 …`.
  static String _describe(OutcomeRow row) {
    final what = row.name.isEmpty ? row.action : '${row.action} ${row.name}';
    return row.detail.isEmpty ? what : '$what: ${row.detail}';
  }

  static final RegExp _newline = RegExp(r'\r\n|\r|\n');
  static final RegExp _whitespace = RegExp(r'\s', unicode: true);

  @override
  bool operator ==(Object other) =>
      other is SyncFailure &&
      other.kind == kind &&
      other.headline == headline &&
      other.details == details;

  @override
  int get hashCode => Object.hash(kind, headline, details);

  @override
  String toString() => 'SyncFailure(${kind.wire}: $headline)';
}
