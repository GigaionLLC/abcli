// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Every provider in the app, in one file.
///
/// One file because the wiring is the part that has to be read as a whole: which store gets which
/// client, what the client is scoped by, and — most of all — what is deliberately NOT a provider.
/// The stores import this file back, which makes the two mutually importing libraries; that is
/// legal Dart and is the honest shape of the dependency, because a `Notifier` reaches its
/// collaborators through `ref` and there is nowhere else for the graph to live.
///
/// **What is not here: the progress transcript.** `ProgressSink` is a plain `ValueNotifier` behind
/// [progressSinkProvider] — the provider hands out the SINK, never its lines. A provider holding
/// the lines would invalidate every dependent once per stderr line during a plan, which is the
/// starvation bug that blanked the Swift window, ported faithfully into Riverpod. The transcript
/// widget listens to the notifier directly with a `ValueListenableBuilder`, so a burst repaints
/// that subtree and nothing above it. See `progress_sink.dart`.
///
/// **What is not here either: an app-wide `isLoading` or `loadError`.** Loading is a question
/// about a pane ([paneStatusProvider]), about the plan (`gitopsProvider.select((s) => s.plan)`) or
/// about the connection — never about the app.
library;

import 'package:abgui/src/abctl/abctl_client.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/abctl_locator.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/abctl/run_log.dart';
import 'package:abgui/src/models/command_timing.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'command_log_store.dart';
import 'connection_store.dart';
import 'console_store.dart';
import 'gitops_store.dart';
import 'inventory_store.dart';
import 'progress_sink.dart';
import 'settings_store.dart';

// ---------------------------------------------------------------------------------------------
// injection points — overridden by the app at startup, and by tests
// ---------------------------------------------------------------------------------------------

/// abgui's own version, for the run log header.
///
/// Null by default and overridden in `main()` from `package_info_plus`, so that this layer (and
/// every test of it) stays free of plugin channels: reading a plugin needs a Flutter binding,
/// which a plain `test()` does not have. `RunLog` makes the same choice for the same reason.
final Provider<String?> abguiVersionProvider = Provider<String?>((ref) => null);

/// Persisted settings. `SharedPreferences` is asynchronous to open, so this is a `FutureProvider`
/// and every caller awaits `.future`; nothing in this layer blocks a frame on a disk read.
///
/// In a test, call `SharedPreferences.setMockInitialValues({})` before touching a store that
/// persists — otherwise the plugin channel is missing and the store's own catch turns it into
/// "the choice lasts for this session", which is correct behaviour but a confusing thing to be
/// debugging inside a test.
final FutureProvider<SharedPreferences> preferencesProvider =
    FutureProvider<SharedPreferences>((ref) => SharedPreferences.getInstance());

/// Opens the on-disk transcript for a workspace verb.
///
/// A seam, because the real implementation creates directories in the user's log location: a test
/// that exercises the plan path overrides this with an opener that answers null (which is the same
/// thing `RunLog.begin` does on any failure, so the store's null handling is exercised either
/// way). The app leaves the default, so run logs cost nobody a wiring step.
final Provider<RunLogOpener> runLogOpenerProvider = Provider<RunLogOpener>(
  (ref) => RunLog.begin,
);

// ---------------------------------------------------------------------------------------------
// the process seam
// ---------------------------------------------------------------------------------------------

/// The embedded abctl's absolute path, or null if it was not found at startup.
///
/// For display (a Settings row saying which binary is in use). It is NOT the gate on running one:
/// see [_LocatingRunner], which re-resolves at run time so a user who has just fixed
/// `$ABGUI_ABCTL` gets a working command rather than a cached complaint.
final Provider<String?> abctlBinaryProvider = Provider<String?>(
  (ref) => AbctlLocator.tryResolve(),
);

/// WHY the locator came up empty, or null when abctl was found.
///
/// The failure is worth its own provider because it is the app's most likely first frame: a
/// developer running `flutter run` has no binary beside the executable, and a packaging mistake
/// gives a shipped user the same state. Both need the same thing on screen — the list of paths
/// that were probed — and neither is served by nineteen screens each discovering independently
/// that their read failed.
///
/// It re-probes rather than reusing [abctlBinaryProvider]'s null because only [AbctlMissingBinary]
/// carries the searched paths and the `$ABGUI_ABCTL` note. That second walk costs a handful of
/// `stat` calls exactly once — a provider is cached, and the pair is invalidated together when
/// the user asks abgui to look again.
final Provider<AbctlMissingBinary?> abctlMissingProvider =
    Provider<AbctlMissingBinary?>((ref) {
      if (ref.watch(abctlBinaryProvider) != null) return null;
      try {
        AbctlLocator.resolve();
        return null;
      } on AbctlMissingBinary catch (error) {
        return error;
      }
    });

/// The transcript sink for the GitOps verbs. Disposed with the container: a live coalescing timer
/// would otherwise keep the event loop awake after the app (or a test) is done with it.
final Provider<ProgressSink> progressSinkProvider = Provider<ProgressSink>((
  ref,
) {
  final sink = ProgressSink();
  ref.onDispose(sink.dispose);
  return sink;
});

/// Builds the process-level runner, told where (if anywhere) its stderr narration should go.
typedef AbctlRunnerFactory =
    AbctlRunner Function({void Function(String line)? onStderrLine});

/// The process seam, and the ONE thing a test should override.
///
/// Overriding a client provider instead would bypass everything between it and here — the command
/// log, the redaction, the `$ abctl …` / `→ exit 0 in 2.4s` transcript lines — so a test could pass
/// while the wiring under it was wrong in exactly the ways that matter. Overriding this leaves all
/// of that in place and replaces only the part that would spawn a process.
final Provider<AbctlRunnerFactory> abctlRunnerFactoryProvider =
    Provider<AbctlRunnerFactory>((ref) {
      final binary = ref.watch(abctlBinaryProvider);
      return ({void Function(String line)? onStderrLine}) => binary == null
          ? _LocatingRunner(onStderrLine: onStderrLine)
          : ProcessRunner(executable: binary, onStderrLine: onStderrLine);
    });

/// The runner every ordinary read uses: recorded, but silent.
final Provider<AbctlRunner> _silentRunnerProvider = Provider<AbctlRunner>(
  (ref) => _runner(ref, narrating: false),
);

/// The runner for the verbs slow enough to need live output. Its stderr streams into the progress
/// sink, and its `$ abctl …` / `→ exit 0 in 2.4s` lines interleave into the same transcript.
final Provider<AbctlRunner> _narratingRunnerProvider = Provider<AbctlRunner>(
  (ref) => _runner(ref, narrating: true),
);

/// Build a runner, recording into the command log and optionally narrating into the transcript.
///
/// The recording wrapper is why "show me the CLI command" costs nothing per verb: every abgui
/// action funnels through the one `AbctlRunner.run` seam, so ONE decorator captures the whole
/// command surface — including verbs added later, which get recorded without anyone remembering
/// to instrument them.
AbctlRunner _runner(Ref ref, {required bool narrating}) {
  final sink = ref.watch(progressSinkProvider);
  final log = ref.read(commandLogProvider.notifier);
  // `sink.add`, the BUFFERED path, for the stderr stream: this fires once per line, and one
  // published update per line is the starvation bug the sink exists to prevent.
  final base = ref.watch(abctlRunnerFactoryProvider)(
    onStderrLine: narrating ? sink.add : null,
  );
  return RecordingRunner(
    wrapped: base,
    onStart: (record) {
      log.start(record);
      // `addNow`, not `add`: this line has to land ahead of the narration the command is about to
      // produce, and the buffered path would let the first stderr line overtake it.
      if (narrating) sink.addNow(record.startLogLine);
    },
    onFinish: (id, status) {
      final finished = log.finish(id, status);
      // A null record aged out of the cap — there is nothing truthful to print for a command
      // whose start is no longer on screen.
      if (narrating && finished != null) sink.addNow(finished.finishLogLine);
    },
  );
}

/// Used when the locator came up empty at startup. It resolves AGAIN at run time, so the failure
/// a user sees is current, and the thrown [AbctlMissingBinary] carries every path that was
/// searched — which for a packaging bug is the entire diagnosis.
///
/// This is why no store in this layer contains the string "abctl was not found in the app bundle":
/// the Swift original spelled that sentence at eight callsites, each of which had to remember to,
/// and none of which could say where it had looked.
class _LocatingRunner implements AbctlRunner {
  const _LocatingRunner({this.onStderrLine});

  final void Function(String line)? onStderrLine;

  @override
  Future<AbctlResult> run(
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    Duration timeout = AbctlTimeouts.read,
    CancelToken? cancel,
  }) async {
    final executable = AbctlLocator.resolve();
    return ProcessRunner(
      executable: executable,
      onStderrLine: onStderrLine,
    ).run(args, cwd: cwd, stdin: stdin, timeout: timeout, cancel: cancel);
  }
}

// ---------------------------------------------------------------------------------------------
// the typed client
// ---------------------------------------------------------------------------------------------

/// The read verbs, silent. Every store but the plan uses this one.
final Provider<AbctlClient> abctlClientProvider = Provider<AbctlClient>(
  (ref) => _client(ref, ref.watch(_silentRunnerProvider)),
);

/// The same client, narrating into the progress transcript. `diff` uses it; nothing else needs to,
/// and wiring a list fetch through it would spray the diff screen with a device inventory.
final Provider<AbctlClient> narratingClientProvider = Provider<AbctlClient>(
  (ref) => _client(ref, ref.watch(_narratingRunnerProvider)),
);

/// Scope the client to the tenant and the workspace.
///
/// Both come from LEAF notifiers ([activeContextProvider], [workspaceProvider]) that depend on
/// nothing. That is what keeps the graph acyclic: every store reaches the client, so a client that
/// watched a store's state would close a loop the moment that store used it — Riverpod asserts on
/// exactly this, and it is right to, because the value would be read from a provider mid-build.
/// It also means the client is rebuilt only when the tenant or the folder really changes, never on
/// a spinner flip or a progress-driven update.
AbctlClient _client(Ref ref, AbctlRunner runner) {
  final context = ref.watch(activeContextProvider);
  final workspace = ref.watch(workspaceProvider);
  return AbctlClient(
    runner: runner,
    // Empty means "abctl's own current context"; an empty `--context` flag is not the same thing
    // and is not a command that works. See AbctlArgs.contextSuffixed.
    context: context.isEmpty ? null : context,
    workspace: workspace,
  );
}

// ---------------------------------------------------------------------------------------------
// the stores
// ---------------------------------------------------------------------------------------------

/// Every abctl invocation this session, and the per-verb timing rolled up from it.
final NotifierProvider<CommandLogStore, CommandLog> commandLogProvider =
    NotifierProvider<CommandLogStore, CommandLog>(CommandLogStore.new);

/// The roll-up, computed once per change to the log rather than once per widget that draws it.
final Provider<List<CommandTiming>> commandTimingProvider =
    Provider<List<CommandTiming>>(
      (ref) => ref.watch(commandLogProvider).timings,
    );

/// abctl's version and the tenant's identity.
final NotifierProvider<ConnectionStore, Connection> connectionProvider =
    NotifierProvider<ConnectionStore, Connection>(ConnectionStore.new);

/// The two SCOPING values, and the only two leaves in this graph: which tenant every command names
/// (`--context`) and which directory every command runs in. Everything else may read them; they
/// read nothing, which is what makes the client buildable from both without a cycle.
final NotifierProvider<ActiveContextStore, String> activeContextProvider =
    NotifierProvider<ActiveContextStore, String>(ActiveContextStore.new);

/// The GitOps workspace path. Owned here rather than inside `GitopsState` for the reason above;
/// the plan and the report that are computed FROM it live in [gitopsProvider].
final NotifierProvider<WorkspaceStore, String?> workspaceProvider =
    NotifierProvider<WorkspaceStore, String?>(WorkspaceStore.new);

/// Saved connections (read-only) plus theme and density.
final NotifierProvider<SettingsStore, Settings> settingsProvider =
    NotifierProvider<SettingsStore, Settings>(SettingsStore.new);

/// The typed console: its transcript, its history, and the read-only guard that decides whether a
/// typed command is allowed to reach abctl at all. The guard is on the STORE and not on the
/// screen, so a disabled Run button is a convenience rather than the guarantee.
final NotifierProvider<ConsoleStore, ConsoleState> consoleProvider =
    NotifierProvider<ConsoleStore, ConsoleState>(ConsoleStore.new);

/// The read-only caches, one independent load per pane.
final NotifierProvider<InventoryStore, Inventory> inventoryProvider =
    NotifierProvider<InventoryStore, Inventory>(InventoryStore.new);

/// The workspace, the plan and the verification report.
final NotifierProvider<GitopsStore, GitopsState> gitopsProvider =
    NotifierProvider<GitopsStore, GitopsState>(GitopsStore.new);

// ---------------------------------------------------------------------------------------------
// per-pane slices
// ---------------------------------------------------------------------------------------------
//
// A screen watches ITS pane, never the cache. Riverpod compares the selected value, so a Devices
// fetch cannot rebuild the Users table even though both slices live in one `Inventory` — the same
// isolation the store enforces on the write side, enforced again on the read side so a careless
// `ref.watch(inventoryProvider)` in a view is the only way to lose it.

/// Whether one pane is busy, what failed on it, and when it last read cleanly.
final ProviderFamily<PaneStatus, InventoryPane> paneStatusProvider =
    Provider.family<PaneStatus, InventoryPane>(
      (ref, pane) =>
          ref.watch(inventoryProvider.select((state) => state.status(pane))),
    );

/// One pane's rows. Identity-stable: the same list object comes back until that pane loads again,
/// so the select above it does no work on an unrelated change and a table of five thousand devices
/// is never compared element by element.
final ProviderFamily<List<Resource>, InventoryPane> paneResourcesProvider =
    Provider.family<List<Resource>, InventoryPane>(
      (ref, pane) =>
          ref.watch(inventoryProvider.select((state) => state.resources(pane))),
    );
