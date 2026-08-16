// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The typed outcome of one abctl invocation, mapped from its exit code + stderr
/// (see `docs/abgui-design.md` §2.5). Ported from the Swift `AbctlError` enum.
///
/// Two deliberate departures from the Swift original, both forced by the language:
///
///  * **Cancellation is a member of this family.** Swift threw Foundation's
///    `CancellationError`, which sits outside `AbctlError` because the runtime owns it.
///    Dart has no structured concurrency and therefore no such type, so cancellation is
///    modelled here — see [AbctlCancelled]. Keeping it inside the sealed family is what
///    lets a `switch` over an abctl failure be exhaustive, which is how a caller is
///    stopped from quietly presenting "the user pressed Cancel" as a tenant error.
///  * **[AbctlMissingBinary] is new.** macOS had exactly one place the embedded CLI could
///    live, so a nil from the locator needed no explanation. Three platforms with three
///    bundle layouts do: when the binary is missing, the list of paths that were searched
///    IS the bug report, and it has to survive into the message a user can copy.
library;

/// A typed abctl failure. `sealed` so every consumer's `switch` is checked at compile
/// time — a new case (there will be one) breaks the build instead of falling into a
/// `default:` that renders it as a generic error.
sealed class AbctlError implements Exception {
  const AbctlError();

  /// The user-facing sentence. Named for its job rather than mirroring Swift's
  /// `errorDescription`, but it is the same string with the same wording rules: it is
  /// shown verbatim in a banner, so it says what happened and what to do about it.
  String get message;

  @override
  String toString() => message;

  /// Map a termination status onto the taxonomy (`docs/abgui-design.md` §2.5).
  ///
  /// The exit codes are abctl's contract and are NOT interchangeable:
  ///  * `0` — success.
  ///  * `3` — "changes pending". A NORMAL state, not a failure: `diff --exit-on-diff`
  ///    returns it when the tenant has drifted from git. Presenting it as breakage is a
  ///    bug in the consumer, which is why it gets its own case rather than sharing the
  ///    error case with a code attached.
  ///  * `1` — a runtime error abctl already explained on stderr, so stderr IS the message.
  ///  * anything else — abctl rejected the argv (Cobra usage errors exit 2 and friends).
  ///    That is a bug in abgui's own command construction, not something a user did, so it
  ///    is separated from `1` to keep the two apart in bug reports.
  static void checkExit({required int code, required String stderr}) {
    switch (code) {
      case 0:
        return;
      case 3:
        throw const AbctlChangesPending();
      case 1:
        throw AbctlCliError(stderr);
      default:
        throw AbctlUsageError(stderr);
    }
  }
}

/// Exit 1: a runtime error / aborted write. Carries abctl's own stderr, which has already
/// been written for a human and beats anything abgui could paraphrase.
final class AbctlCliError extends AbctlError {
  const AbctlCliError(this.stderr);

  final String stderr;

  @override
  String get message => stderr.isEmpty ? 'abctl reported an error.' : stderr;
}

/// Any other non-0/non-3 exit — almost always an argv bug on abgui's side.
final class AbctlUsageError extends AbctlError {
  const AbctlUsageError(this.stderr);

  final String stderr;

  @override
  String get message => 'unexpected abctl exit: $stderr';
}

/// Exit 0, but stdout did not decode. Keeps the underlying decoder failure so a bug report
/// can name the field, rather than collapsing every JSON problem into one sentence.
final class AbctlDecodeError extends AbctlError {
  const AbctlDecodeError(this.cause);

  final Object cause;

  @override
  String get message => 'could not decode abctl output: $cause';
}

/// Exit 3: drift/plan pending. A normal state that several callers catch and render as
/// data; it is an error only in the sense that it interrupts the happy path.
final class AbctlChangesPending extends AbctlError {
  const AbctlChangesPending();

  @override
  String get message => 'changes pending.';
}

/// The run outstayed its timeout and abgui killed it.
///
/// [lastOutput] is whatever abctl printed on stderr before it hung, which is very often
/// the single most diagnostic thing available — "fetching profile 340/1200" and "waiting
/// for token" are different bugs, and the exit status can no longer tell them apart once
/// we are the ones who ended the process.
final class AbctlTimedOut extends AbctlError {
  const AbctlTimedOut({required this.seconds, required this.lastOutput});

  /// How long abgui waited, in whole seconds — the number belongs in the message because
  /// "it timed out" invites the reply "after how long?" from every single reporter.
  final int seconds;

  /// abctl's stderr tail at the moment it was killed.
  final String lastOutput;

  @override
  String get message {
    // Timeouts are almost always the network round-trip to Apple, so name the likely
    // causes and show whatever abctl managed to print before it hung.
    final waited = seconds >= 1 ? '${seconds}s' : 'under a second';
    var msg =
        'abctl ran for $waited without finishing and was stopped. It reaches Apple\'s API '
        '(api-business.apple.com and account.apple.com) for live data, so this is usually a slow or '
        'blocked network (VPN/proxy/firewall), a rate-limited token, or credentials that aren\'t set. '
        'This limit is abgui\'s command guardrail, not an Apple timeout; large tenants can spend several '
        'minutes fetching per-profile detail before writes begin. '
        'Check the connection dot in the sidebar; for diff/apply, also confirm the chosen folder '
        'contains a gitops/ tree.';
    final tail = lastOutput.trim();
    if (tail.isNotEmpty) {
      msg += '\n\nLast output from abctl:\n$tail';
    }
    return msg;
  }
}

/// The caller cancelled the run and the child was killed.
///
/// Distinct from every other case on purpose: a cancelled command is not a failure, and a
/// consumer that reports it as one trains users to ignore error banners.
final class AbctlCancelled extends AbctlError {
  const AbctlCancelled();

  @override
  String get message => 'the command was cancelled.';
}

/// The embedded abctl binary could not be found (or is not executable).
///
/// The searched paths are part of the message because this failure is nearly always a
/// packaging bug, and "which paths did it look in" is the entire diagnosis.
final class AbctlMissingBinary extends AbctlError {
  const AbctlMissingBinary({required this.searched, this.detail});

  /// Every absolute path that was probed, in probe order.
  final List<String> searched;

  /// Optional extra context, e.g. that `$ABGUI_ABCTL` pointed at something unusable —
  /// a developer override that silently falls back to the bundled binary is a debugging
  /// session nobody needs to have twice.
  final String? detail;

  @override
  String get message {
    final where = searched.isEmpty
        ? ''
        : '\n\nLooked in:\n${searched.map((p) => '  $p').join('\n')}';
    final why = detail == null ? '' : '\n\n$detail';
    return 'The abctl command-line tool that ships inside this app could not be found. '
        'This is a packaging problem, not something you did; reinstalling the app is the fix. '
        'A developer can point abgui at a locally built CLI by setting ABGUI_ABCTL to its path.'
        '$why$where';
  }
}
