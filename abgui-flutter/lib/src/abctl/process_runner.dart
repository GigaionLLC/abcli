// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:abgui/src/models/command_record.dart';

import 'abctl_error.dart';

/// The raw result of one abctl invocation: the three streams of abctl's contract kept
/// separate — stdout (the machine payload), stderr (human status), and the exit code.
///
/// stdout stays BYTES. abctl's `-o json` payload is decoded by the layer above, and a
/// `configuration --profile` payload is XML that is written straight back out; forcing a
/// `String` here would mean decoding and re-encoding every profile abgui ever touches.
class AbctlResult {
  const AbctlResult({
    required this.stdout,
    required this.stderr,
    required this.code,
  });

  final Uint8List stdout;
  final String stderr;
  final int code;

  /// stdout as text, tolerant of malformed bytes. Never throws: a decode failure here would
  /// destroy the diagnostics of a run that has already gone wrong in some other way.
  String get stdoutText => utf8.decode(stdout, allowMalformed: true);

  bool get isSuccess => code == 0;

  /// Exit 3 is abctl's "changes pending" verdict — drift between git and the tenant. It is a
  /// NORMAL state, not a failure, and lives here as a named getter so no consumer has to
  /// remember which magic number means "fine, actually".
  bool get changesPending => code == 3;

  /// Throw the typed error this exit code maps to (see [AbctlError.checkExit]).
  void checkExit() => AbctlError.checkExit(code: code, stderr: stderr);
}

/// The mockable seam. Everything above `AbctlRunner` is pure logic that can be tested with a
/// canned runner and no binary.
abstract interface class AbctlRunner {
  /// Run abctl with [args], optionally in [cwd], optionally feeding [stdin].
  ///
  /// [cancel] is how a run is stopped; see [CancelToken] for why cancellation is a parameter
  /// rather than something handed back to the caller.
  ///
  /// [timeout] carries no default HERE — an abstract member cannot impose one on its
  /// implementations — but every implementation defaults it to [AbctlTimeouts.read], so a
  /// call through this interface that omits it still gets the plain read budget rather than
  /// running unbounded. A verb with a different budget must say so; see [AbctlTimeouts].
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout,
    CancelToken? cancel,
  });
}

/// The per-verb command budgets, ported from the Swift `AbctlClient`. They live down here
/// with the runner because the runner is what enforces them, and because the client that
/// spends them does not exist yet in this rewrite — losing the numbers would mean
/// rediscovering each one the way it was found the first time, on a real tenant.
abstract final class AbctlTimeouts {
  /// A plain read: one or two API calls.
  static const Duration read = Duration(seconds: 60);

  /// Managing `~/.abctl/contexts.yaml`. Local file I/O, no network.
  static const Duration control = Duration(seconds: 30);

  /// `diff` makes live API calls (and may mint/refresh a token) across the whole tenant.
  static const Duration plan = Duration(seconds: 600);

  /// `sync --apply`: the plan, plus every write, plus post-apply verification.
  static const Duration apply = Duration(seconds: 1200);

  /// The fan-out reads outgrow the plain read budget, so they get double: `status device`
  /// (one relationship call per blueprint + the MDM inventory list), `get usergroup
  /// --members` (one API call per member), and `get mdmserver --devices` (walks the whole
  /// org device inventory to resolve serials).
  static const Duration fanOut = Duration(seconds: 120);

  /// `validate` only reads local files, but a big lib/ plus a slow external
  /// `$ABCTL_VALIDATOR` still deserves more than the plain read budget.
  static const Duration validate = Duration(seconds: 120);

  /// Membership verbs (attach / detach / adopt) are multi-call: resolve the blueprint, list
  /// configurations for name↔id, read the blueprint's current members, then write. The plain
  /// 60s read budget killed `adopt` mid-flight on a real tenant and left the manifest
  /// unwritten while reporting only "abctl ran for 60s" — a timeout is indistinguishable from
  /// a broken feature. The per-call cost is fixed on the abctl side; this is the headroom for
  /// a slow network or a large tenant on top of that.
  static const Duration membership = Duration(seconds: 180);

  /// `create` / `replace` / `delete` configuration. The same 180s as [membership], for the same
  /// reason and with more at stake.
  ///
  /// These are not single API calls either: a `replace` fetches the live profile, archives it to
  /// `gitops/archive/`, PATCHes Apple, rewrites `gitops/lib/` and the baseline, and — under the
  /// default `--verify` — reads it back. On the plain 60s read budget a large profile on a big
  /// tenant loses the watchdog race somewhere in the middle of that, and the operator is handed
  /// [AbctlTimedOut]'s message: "usually a slow or blocked network (VPN/proxy/firewall), a
  /// rate-limited token, or credentials that aren't set". That is a network diagnosis for a
  /// tenant write that has already landed and a git half that may not have. The Swift original
  /// passed no timeout here at all and therefore inherited its 60s default; that is the bug this
  /// port is fixing rather than reproducing, because this repo already paid for the lesson once —
  /// see [membership].
  static const Duration write = Duration(seconds: 180);

  /// `seed` downloads live configurations + blueprints into the workspace tree.
  static const Duration seed = Duration(seconds: 120);

  /// An operator-typed command in the console. Generous, because the operator chose it.
  static const Duration console = Duration(seconds: 600);
}

/// Cancellation, modelled explicitly because Dart has none.
///
/// **Why a token the caller passes DOWN, and not a handle the runner hands BACK.** Swift got
/// cancellation from structured concurrency: `Task.cancel()` on the task the UI already held
/// propagated into `ProcessRunner.run` for free, through every layer in between, and the
/// `withTaskCancellationHandler` there killed the child. Dart has no equivalent — a `Future`
/// cannot be cancelled — so the mechanism has to be carried by hand, and the two candidates
/// are not equivalent:
///
///  * A **handle** (`start()` returns something with `cancel()`) only reaches whoever calls
///    the runner directly. In this app that is never the UI: the Cancel button lives beside a
///    view model, which calls a client method that decodes a model, which calls a decorator,
///    which calls the runner. Every one of those layers would have to change its return type
///    to carry the handle back up — and a decorator that forgets to forward it silently
///    produces a Cancel button that does nothing.
///  * A **token** passes DOWN through signatures that already exist, so `AbctlRunner`
///    implementations (the recorder, a mock, a future retrying runner) forward one extra
///    named argument and nothing else. The caller creates it before the work starts, which
///    also means it can cover a SEQUENCE of commands — "cancel the sync" is one token across
///    the plan, the apply and the verify, where a per-child handle would be three.
///
/// A token is single-use and idempotent: once cancelled it stays cancelled, and a run handed
/// an already-cancelled token fails immediately without spawning anything. Listeners fire
/// synchronously inside [cancel] — they only send a signal to a child process, and deferring
/// that to a microtask would leave the child running for one more turn of the event loop
/// while the UI already claims the operation is over.
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  /// Stop the work. Safe to call any number of times, and safe to call before the run starts.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    // Copy first: a listener that removes itself (they all do, via the closure returned by
    // `onCancel`) would otherwise mutate the list mid-iteration.
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// Register [listener], returning the function that unregisters it. Callers MUST call that
  /// function when their work finishes: a long-lived token (one per sync, say) would
  /// otherwise accumulate a closure per command, each holding a dead `Process` alive.
  ///
  /// If the token is already cancelled the listener runs immediately, so there is no window
  /// in which a `cancel()` between "check `isCancelled`" and "register" gets lost.
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return _noop;
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  static void _noop() {}
}

/// Runs the embedded abctl as a subprocess, draining stdout/stderr concurrently with the wait
/// so a full pipe buffer can never deadlock the child.
///
/// Ported from the Swift `ProcessRunner` actor. Dart needs no actor: one isolate, one event
/// loop, and `dart:io` process I/O is already asynchronous, so nothing here blocks the frame
/// that a Swift `Process.waitUntilExit()` would have blocked.
class ProcessRunner implements AbctlRunner {
  ProcessRunner({required this.executable, this.onStderrLine});

  /// Absolute path to the abctl binary — never a bare name resolved through `PATH`. A
  /// GUI-launched process inherits a minimal environment on every one of the three
  /// platforms, so a `PATH` lookup is a coin flip that works on the developer's machine.
  final String executable;

  /// Called with each stderr line as abctl prints it (progress narration). Unlike the Swift
  /// original this arrives on the caller's own isolate, so a UI consumer can touch state
  /// directly — there is no main-actor hop to remember.
  final void Function(String line)? onStderrLine;

  /// How long a terminated child gets to die politely before it is killed outright. SIGTERM
  /// is a request; a child wedged inside an uninterruptible syscall can ignore it, and if it
  /// does, the drains below never see EOF and the caller waits forever — the exact hang the
  /// timeout exists to prevent, reached by way of the timeout itself.
  static const Duration killGrace = Duration(seconds: 5);

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    // Already cancelled: spawn nothing. Starting a child only to kill it a microtask later
    // still runs whatever abctl does before its first cancellation point.
    if (cancel != null && cancel.isCancelled) {
      throw const AbctlCancelled();
    }

    final Process process;
    try {
      process = await Process.start(executable, args, workingDirectory: cwd);
    } on ProcessException catch (error) {
      // No exit code exists for a child that never started, so this cannot go through the
      // exit-code mapping — and it must not go through [AbctlCliError] either, which is
      // documented as "exit 1: a runtime error, carrying abctl's own stderr". A binary that
      // never ran produced no stderr and no runtime error, and dressing the failure that way
      // sends it down the wrong path everywhere: `GitopsStore._applyFailure` maps it to
      // `SyncFailure.fromAbort`, so the operator reads "could not start abctl at
      // /Applications/abgui.app/…" underneath "Nothing was applied", with nothing on screen
      // saying that reinstalling is the fix.
      //
      // [AbctlMissingBinary] is the type built for that diagnosis, and until now it was only
      // reachable from the STARTUP probe (`_LocatingRunner`). A binary that resolved at launch
      // and became unrunnable afterwards — quarantined by Gatekeeper or AV after an update, its
      // permission bits stripped, a network volume unmounted, the app upgraded underneath a
      // running process — is the same packaging problem discovered later, and now says so.
      throw AbctlMissingBinary(
        searched: <String>[executable],
        detail:
            'abgui found this path but the operating system refused to start it: '
            '${error.message}',
      );
    }

    var timedOut = false;
    var terminating = false;
    Timer? watchdog;
    Timer? escalation;

    void terminate() {
      if (terminating) return;
      terminating = true;
      process.kill(ProcessSignal.sigterm);
      escalation = Timer(killGrace, () => process.kill(ProcessSignal.sigkill));
    }

    // Watchdog: if the child outstays `timeout`, terminate it. That closes its pipes (so the
    // drains below reach EOF) and lets the exit-code future complete — a wedged or
    // network-hung abctl can never freeze the caller forever. Cancelled on success.
    if (timeout > Duration.zero) {
      watchdog = Timer(timeout, () {
        timedOut = true;
        terminate();
      });
    }

    // If the caller cancels (a Cancel button), terminate the child so it doesn't linger; its
    // pipes then close, the drains reach EOF, and we unwind below exactly as for a timeout.
    final unregisterCancel = cancel?.onCancel(terminate) ?? _noop;

    // ---- the deadlock-critical section -------------------------------------------------
    //
    // Subscribe to BOTH pipes here, BEFORE anything below awaits. A pipe holds ~64 KB; once
    // it is full the child blocks inside `write` and never reaches exit, while the parent
    // blocks waiting for an exit that cannot happen. Draining one stream to completion first
    // and only then subscribing to the other is the same bug wearing a Dart costume: abctl
    // narrates on stderr for the whole run and prints the JSON payload on stdout at the end,
    // so "read stdout fully, then read stderr" wedges on the first large plan.
    //
    // `listen` registers synchronously, so by the end of these few statements both pipes are
    // being drained no matter what the rest of this function does.
    final stdoutBytes = BytesBuilder(copy: false);
    final stderrBytes = BytesBuilder(copy: false);
    final stdoutDrained = _drain(process.stdout, stdoutBytes.add);

    // stderr is teed: the bytes accumulate for the result (and for a timeout's `lastOutput`)
    // while a copy goes through a UTF-8 + line splitter for live narration. Splitting on the
    // decoded stream rather than hand-scanning for 0x0A is what keeps a multi-byte character
    // straddling two chunks from being torn in half.
    StreamController<List<int>>? lineFeed;
    Future<void> linesDone = Future<void>.value();
    final onLine = onStderrLine;
    if (onLine != null) {
      lineFeed = StreamController<List<int>>();
      linesDone = lineFeed.stream
          // allowMalformed: abctl can echo a byte sequence from Apple's error body that is
          // not valid UTF-8, and losing the whole progress stream over one bad byte would
          // trade a cosmetic problem for a blind run.
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) return;
            try {
              onLine(trimmed);
            } catch (_) {
              // A narration listener is a nice-to-have; the command is not. Swift could not have
              // this problem (the closure type is non-throwing), but in Dart an exception here
              // would ride the transformed stream out through `linesDone` and fail an apply that
              // is otherwise going perfectly well — because a progress label could not be drawn.
            }
          });
    }
    final feed = lineFeed;
    final stderrDrained = _drain(
      process.stderr,
      (chunk) {
        stderrBytes.add(chunk);
        feed?.add(chunk);
      },
      onDone: () {
        feed?.close();
      },
    );

    // Feed stdin (profile XML for `create -f -`) INSIDE the watchdog's and the cancel
    // handler's reach, and only AFTER both drains are live. Started, deliberately not
    // awaited: a profile larger than the pipe buffer sent to an abctl that narrates before
    // consuming stdin deadlocks both ends if nobody is reading the child's output while the
    // write is in flight.
    final stdinWrite = _writeStdin(process.stdin, stdin);
    // ------------------------------------------------------------------------------------

    try {
      await stdoutDrained;
      await stderrDrained;
      await linesDone;
      // The write error is captured rather than discarded, because a partially written
      // profile is a TRUNCATED one, and sending that to Apple as a `create` is worse than
      // failing outright — the exit code alone cannot tell "created what you meant" from
      // "created half of it".
      final stdinError = await stdinWrite;
      final code = await process.exitCode;

      final stderrText = utf8.decode(
        stderrBytes.takeBytes(),
        allowMalformed: true,
      );

      // Order matters, and it differs from the Swift original on purpose. Swift reported a
      // stdin write failure FIRST; but when we are the ones who killed the child, the broken
      // pipe that failed the write is a CONSEQUENCE of the kill, and reporting "abctl may
      // have received only part of the profile" hides the real story ("it never answered for
      // 600s"). So the two outcomes we caused are checked first, and the write error is what
      // it means only when the child died on its own terms.
      if (cancel != null && cancel.isCancelled) {
        throw const AbctlCancelled();
      }
      if (timedOut) {
        // Hand back what abctl printed before it hung (usually the most diagnostic thing)
        // plus how long we waited, so the UI shows an actionable message.
        throw AbctlTimedOut(seconds: timeout.inSeconds, lastOutput: stderrText);
      }
      if (stdinError != null) {
        throw AbctlCliError(
          'failed to send the profile to abctl (it may have received only part of it): '
          '$stdinError\n$stderrText',
        );
      }

      return AbctlResult(
        stdout: stdoutBytes.takeBytes(),
        stderr: stderrText,
        code: code,
      );
    } finally {
      // Every exit path, including the throws above: a live watchdog would kill a process
      // that has already exited (harmless) and, worse, keep the isolate's event loop alive
      // for the remainder of the budget — 20 minutes, for an apply, in a test suite.
      watchdog?.cancel();
      escalation?.cancel();
      unregisterCancel();
    }
  }

  /// Subscribe now, complete at EOF. Errors are swallowed rather than propagated: a read
  /// error on a pipe whose child we just killed is noise, and the interesting failure is
  /// always the exit code or the timeout, both of which are still reported.
  static Future<void> _drain(
    Stream<List<int>> stream,
    void Function(List<int> chunk) sink, {
    void Function()? onDone,
  }) {
    final done = Completer<void>();
    stream.listen(
      sink,
      onError: (Object _) {},
      onDone: () {
        onDone?.call();
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );
    return done.future;
  }

  /// Write [data] to the child's stdin and CLOSE it, returning the error if the write failed.
  ///
  /// Closing happens either way, and that is the important half: without EOF the child waits
  /// for input that is never coming, which is a hang rather than an error — and a hang is
  /// what the timeout would then report, for a bug that has nothing to do with the network.
  ///
  /// A failure to CLOSE after a successful flush is deliberately not reported: the bytes are
  /// already in the pipe at that point, and the usual cause is a child that has exited and
  /// closed its end, which is not truncation.
  static Future<Object?> _writeStdin(IOSink sink, List<int>? data) async {
    Object? failure;
    try {
      if (data != null && data.isNotEmpty) {
        sink.add(data);
        // `add` is fire-and-forget on an IOSink: errors (a broken pipe, a child that died
        // mid-profile) surface here or on `done`, so the flush is what makes the write
        // checkable at all.
        await sink.flush();
      }
    } catch (error) {
      failure = error;
    }
    try {
      await sink.close();
    } catch (_) {
      // Already covered above when it matters.
    }
    return failure;
  }

  static void _noop() {}
}

/// An [AbctlRunner] decorator that reports every invocation to a sink, then forwards it
/// untouched to the real runner.
///
/// This is why "show me the CLI command" costs almost nothing here: every abgui action
/// already funnels through the single `AbctlRunner.run` seam, so ONE wrapper captures the
/// whole command surface — including verbs added later, which get recorded without anyone
/// remembering to instrument them. Nothing above this layer knows it is being watched.
class RecordingRunner implements AbctlRunner {
  const RecordingRunner({
    required this.wrapped,
    required this.onStart,
    required this.onFinish,
  });

  final AbctlRunner wrapped;

  /// Called with the redacted record the instant the command starts, so the UI can show it
  /// while the child is still running rather than only in hindsight.
  final void Function(CommandRecord record) onStart;

  /// Called once with the terminal status, keyed by the record's id.
  final void Function(String id, CommandStatus status) onFinish;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    // CommandRecord's constructor redacts, so the secret never reaches the sink.
    final record = CommandRecord(
      argv: args,
      cwd: cwd,
      stdin: stdin == null
          ? const CommandStdin.none()
          : CommandStdin.profile(bytes: stdin.length),
    );
    onStart(record);
    try {
      final result = await wrapped.run(
        args,
        cwd: cwd,
        stdin: stdin,
        timeout: timeout,
        cancel: cancel,
      );
      onFinish(
        record.id,
        result.code == 0
            ? CommandStatus.succeeded
            : CommandStatus.failed(result.code),
      );
      return result;
    } on AbctlCancelled {
      onFinish(record.id, CommandStatus.cancelled); // not a failure
      rethrow;
    } on AbctlTimedOut {
      // A timeout is abgui's own guardrail rather than an abctl exit code, so it gets its own
      // status instead of masquerading as one (`exit -1` would read as a real result).
      onFinish(record.id, CommandStatus.timedOut);
      rethrow;
    } catch (_) {
      // Everything else — a mapped CLI error, a spawn failure, a bug in a wrapped runner.
      // No exit code exists for most of these, hence the sentinel.
      onFinish(record.id, const CommandStatus.failed(-1));
      rethrow;
    }
  }
}
