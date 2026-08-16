// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/abctl/run_log.dart';
import 'package:abgui/src/models/apply_result.dart';
import 'package:abgui/src/models/command_record.dart';
import 'package:abgui/src/models/json.dart' show listEquals;
import 'package:abgui/src/models/plan.dart';
import 'package:abgui/src/models/sync_failure.dart';
import 'package:abgui/src/models/validation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_store.dart';
import 'load_token.dart';
import 'providers.dart';

/// Opens a run log. A seam so the state layer can be exercised without writing files into the
/// developer's log directory; the app wires [RunLog.begin] through `runLogOpenerProvider`.
typedef RunLogOpener = Future<RunLog?> Function(RunLogHeader header);

/// The drift computation: `abctl diff --json`, its verdict, and why it might have none.
///
/// Its own value type, so a widget can `select` it and a validation run — which shares nothing
/// with it but a workspace — cannot rebuild the plan table. Every transition below returns a new
/// instance and states explicitly what survives it; a `copyWith` with nullable arguments cannot
/// express "clear the error but keep the plan", which is most of what happens here.
class PlanState {
  const PlanState({
    this.plan,
    this.isRunning = false,
    this.error,
    this.note,
    this.checkedAt,
    this.needsGitopsTree = false,
    this.superseded = false,
  });

  /// The last computed plan. An EMPTY plan and a null one are different answers: empty means git
  /// and the tenant agree, null means nobody has asked yet.
  final Plan? plan;

  final bool isRunning;

  /// A failure to render as a failure.
  final String? error;

  /// A non-alarming remark to render in the dim style — the drift verdict that arrived without a
  /// document to show. See [GitopsStore.refreshPlan]'s changes-pending branch: drift is DATA and
  /// must never be dressed up as breakage, but "abctl said something and printed no plan" still
  /// has to reach the screen rather than looking like nothing happened.
  final String? note;

  /// When the plan was last computed successfully. Stamped on EVERY clean run, including one that
  /// found no drift — otherwise pressing Refresh on an in-sync tenant looks like a dead button.
  final DateTime? checkedAt;

  /// The chosen folder has no `gitops/` tree, so there is nothing to diff against.
  ///
  /// Not a failure — it is the normal first state of a folder somebody has just picked, and it is
  /// what [GitopsStore.seedWorkspace] exists to resolve.
  final bool needsGitopsTree;

  /// A `sync --apply` has run against these rows, so they describe a tenant that no longer
  /// exists.
  ///
  /// The rows are KEPT rather than dropped, and that pairing is the point: they are the record of
  /// what was just applied, which is the most useful thing on screen the minute after an apply —
  /// but they are no longer an answer to "what is pending", and a plan that silently keeps
  /// claiming to be one is how an operator applies the same delete twice. Cleared by the next
  /// successful compute, because [succeeded] builds a fresh state rather than copying this one.
  final bool superseded;

  bool get hasPlan => plan != null;

  /// Spinner up; the previous plan stays on screen (it is still the last true answer) while its
  /// error and note go, because they described a run that is being replaced.
  PlanState started() =>
      PlanState(plan: plan, isRunning: true, checkedAt: checkedAt);

  PlanState succeeded(Plan computed, DateTime at) =>
      PlanState(plan: computed, checkedAt: at);

  /// A failed compute keeps the old plan and the old stamp: the rows really were true as of that
  /// time, and the stamp is what tells the reader they are not fresh.
  PlanState failed(String message) =>
      PlanState(plan: plan, error: message, checkedAt: checkedAt);

  PlanState noted(String message) =>
      PlanState(plan: plan, note: message, checkedAt: checkedAt);

  /// Spinner down, nothing said — the cancelled path. The user asked for it.
  PlanState settled() => PlanState(plan: plan, checkedAt: checkedAt);

  /// Not a workspace (yet). Everything else goes: a plan computed for another folder must not
  /// stay on screen underneath the "this folder has no gitops/ tree" message.
  PlanState needsTree() => const PlanState(needsGitopsTree: true);

  /// A write landed against these rows. See [superseded] for why they stay.
  ///
  /// The error and the note go: both described the COMPUTE, and neither survives the apply that
  /// followed it. The stamp stays, because "these rows were true at 14:02" is exactly what makes
  /// the superseded flag readable.
  PlanState supersededByApply() =>
      PlanState(plan: plan, checkedAt: checkedAt, superseded: true);

  @override
  bool operator ==(Object other) =>
      other is PlanState &&
      other.plan == plan &&
      other.isRunning == isRunning &&
      other.error == error &&
      other.note == note &&
      other.checkedAt == checkedAt &&
      other.needsGitopsTree == needsGitopsTree &&
      other.superseded == superseded;

  @override
  int get hashCode => Object.hash(
    plan,
    isRunning,
    error,
    note,
    checkedAt,
    needsGitopsTree,
    superseded,
  );
}

/// `abctl validate --json`: the local, credential-free check of the workspace's own profiles.
///
/// Owns its own busy flag and its own error for the same reason the panes do — verifying must
/// never blank the diff screen's spinner or overwrite its message.
class ValidationState {
  const ValidationState({
    this.report,
    this.isRunning = false,
    this.error,
    this.checkedAt,
  });

  final ValidationReport? report;
  final bool isRunning;
  final String? error;
  final DateTime? checkedAt;

  ValidationState started() =>
      ValidationState(report: report, isRunning: true, checkedAt: checkedAt);

  /// Stamped whether the report is clean or not: the CHECK completed either way, and "when did I
  /// last verify" is a different question from "did it pass".
  ValidationState succeeded(ValidationReport result, DateTime at) =>
      ValidationState(report: result, checkedAt: at);

  /// A check that failed to COMPLETE leaves verification unknown — the report and the stamp both
  /// go. Keeping the last report would render a green "Verified" row on the strength of a run
  /// that never produced a verdict.
  ValidationState failed(String message) => ValidationState(error: message);

  ValidationState settled() =>
      ValidationState(report: report, checkedAt: checkedAt);

  @override
  bool operator ==(Object other) =>
      other is ValidationState &&
      other.report == report &&
      other.isRunning == isRunning &&
      other.error == error &&
      other.checkedAt == checkedAt;

  @override
  int get hashCode => Object.hash(report, isRunning, error, checkedAt);
}

/// The caller's answer to "there is already a `gitops/` tree in this folder".
///
/// **A named type rather than a `bool overwrite` parameter, for the reason `ApplyOptions` is one:
/// the destructive choice has to be unspellable by accident.** `abctl seed` rewrites the workspace
/// tree from live tenant state, so running it over a checkout with uncommitted work — a profile
/// somebody edited but has not synced — replaces that work with whatever Apple currently has. A
/// boolean argument at a callsite reads as configuration; this reads as consent, and
/// [GitopsStore.seedWorkspace] REFUSES rather than asking, so a screen that forgets to confirm
/// gets a message instead of a rewritten tree.
enum SeedConsent {
  /// Seed only a folder with no `gitops/` tree. The store refuses if it finds one.
  onlyIfAbsent,

  /// The user was shown the tree that is already there and asked for it to be re-seeded anyway.
  overwriteExistingTree,
}

/// `abctl seed`: the workspace tree downloaded from live tenant state.
///
/// **The summary is abctl's own PLAIN TEXT, and nothing here decodes it.** `seed` is the one verb
/// in this app whose stdout is prose rather than a document — "seeded 3 configuration(s)" — so
/// there is no model to parse it into and no shape to validate. It is carried verbatim to the one
/// place that shows it. Trying to decode it would turn a successful seed into a decode failure the
/// moment abctl reworded a sentence.
///
/// Its own value type beside [PlanState] rather than a pair of flags on the store, and its own
/// [LoadGeneration] inside it, because the seed and the plan are exactly the two operations whose
/// shared counter wedged the Swift Diff screen on "Initializing workspace from the tenant…" with
/// every control disabled (see `load_token.dart`).
class SeedState {
  const SeedState({
    this.isRunning = false,
    this.error,
    this.summary,
    this.seededAt,
  });

  final bool isRunning;

  /// A failure to render as a failure — including the refusal to seed over an existing tree.
  final String? error;

  /// What abctl printed, verbatim. Null once dismissed, or when nothing has been seeded.
  final String? summary;

  /// When the last seed completed. Survives a later failure: the tree that seed created is still
  /// on disk, and the stamp is what says how old it is.
  final DateTime? seededAt;

  /// Spinner up. The previous summary and error both go — they describe a run being replaced, and
  /// a stale "workspace initialized" line under a spinner reads as a result that has already
  /// arrived.
  SeedState started() => SeedState(isRunning: true, seededAt: seededAt);

  SeedState succeeded(String text, DateTime at) =>
      SeedState(summary: text, seededAt: at);

  SeedState failed(String message) =>
      SeedState(error: message, seededAt: seededAt);

  /// Spinner down, nothing said — the cancelled path, and the one the refusal does NOT take.
  SeedState settled() => SeedState(summary: summary, seededAt: seededAt);

  /// The user has read the summary. The stamp stays: "when was this tree seeded" outlives the
  /// paragraph that announced it.
  SeedState dismissed() => SeedState(seededAt: seededAt);

  @override
  bool operator ==(Object other) =>
      other is SeedState &&
      other.isRunning == isRunning &&
      other.error == error &&
      other.summary == summary &&
      other.seededAt == seededAt;

  @override
  int get hashCode => Object.hash(isRunning, error, summary, seededAt);
}

/// What became of a `sync --apply` — and the four answers that are NOT interchangeable.
///
/// **The whole existence of this enum is invariant 6 in view form** (`write_safety_test.dart`):
/// a write's success is the outcome DOCUMENT, never the exit code. abctl prints a complete
/// receipt in which every item says `done` and still exits non-zero when the post-apply read-back
/// finds Apple did not persist a write (Apple answers `2xx` to a PATCH it then drops). It also
/// prints a receipt full of `status:"error"` rows for a run that half-applied. Collapsing any of
/// that into a boolean is how "Applied 9 changes" gets printed over a tenant that took three of
/// them.
enum ApplyVerdict {
  /// Nothing has been run from this state yet.
  idle,

  /// abctl is writing right now.
  running,

  /// Every item reported done, abctl exited 0, and the read-back raised no mismatch.
  applied,

  /// Some of it landed. Item errors, a non-zero exit despite clean items, or a verification
  /// mismatch — any ONE of those withholds the green verdict.
  partial,

  /// abctl never produced a receipt AND said why it stopped. It prints the per-item document
  /// before it exits, so a run with no document is one that stopped before writing: bad
  /// credentials, no tree, an Apple 403 while planning. The tenant is as it was.
  failed,

  /// The run ended without telling us what it had already written.
  ///
  /// Two routes reach it, and they are the same situation to the reader even though they are
  /// different events: a cancel or a watchdog kill stops abctl MID-WRITE, and a receipt that will
  /// not decode means abctl finished and abgui cannot read what it did.
  ///
  /// **Deliberately not [failed].** "It failed" tells an operator the tenant is untouched, and
  /// after a half-finished apply that is the most expensive wrong thing they can be told — they
  /// do nothing, and the tenant stays part way between git and where it started. An ambiguous
  /// state has to be reported as ambiguous.
  unknown,
}

/// One `sync --apply` run: abctl's receipt, its verdict, and the transcript it was read from.
///
/// Its own value type beside [PlanState] for the reason every state here is: a widget can
/// `select` it, so the twelve-second window in which a table of outcomes arrives cannot rebuild
/// anything else, and every transition below says explicitly what survives it.
class ApplyState {
  const ApplyState({
    this.isRunning = false,
    this.startedAt,
    this.finishedAt,
    this.result,
    this.failure,
    this.exitCode,
    this.interrupted = false,
    this.transcript = const <String>[],
  });

  final bool isRunning;

  /// When Apply was pressed — what the dialog's live elapsed reading counts from.
  final DateTime? startedAt;

  final DateTime? finishedAt;

  /// abctl's per-item receipt. Present even for a run that exited non-zero: `AbctlClient`
  /// decodes stdout BEFORE it maps the exit code, precisely so a partly-applied tenant write
  /// arrives as data rather than as a stderr blob.
  final ApplyResult? result;

  /// Why the run is not a clean success, ranked to one line with everything it was derived from
  /// kept beside it. Null ONLY when every item reported done and abctl exited 0 — that is the
  /// whole pass/fail test, so nothing else may disagree with it.
  final SyncFailure? failure;

  /// abctl's exit status, kept beside the receipt rather than consumed. Never the verdict on its
  /// own; see [ApplyVerdict].
  final int? exitCode;

  /// The run ended without telling us what it had already written.
  ///
  /// True for a cancel and for a watchdog timeout, and it outranks every other reading of the
  /// state. An apply is not atomic: abctl writes configuration by configuration, so a run stopped
  /// in the middle has usually written SOME of them. Reporting that as a clean failure is the one
  /// mistake on this screen that leads an operator to do nothing when what they must do is
  /// recompute the plan.
  final bool interrupted;

  /// The narration this run produced, snapshotted when it ended.
  ///
  /// Snapshotted rather than read live from `ProgressSink` because the sink belongs to whatever
  /// runs NEXT: the recompute that follows an apply clears it, and the transcript the operator is
  /// still reading would empty itself while they read it.
  final List<String> transcript;

  /// Spinner up, and NOTHING from the previous run survives — an earlier receipt sitting under a
  /// running apply is a table of outcomes that belongs to a different tenant state.
  ApplyState started(DateTime at) =>
      ApplyState(isRunning: true, startedAt: at, transcript: const <String>[]);

  /// abctl printed a receipt. [failure] is null only for a run that was clean end to end.
  ApplyState finished({
    required ApplyResult applied,
    required int code,
    required SyncFailure? failure,
    required List<String> transcript,
    required DateTime at,
  }) => ApplyState(
    startedAt: startedAt,
    finishedAt: at,
    result: applied,
    exitCode: code,
    failure: failure,
    transcript: transcript,
  );

  /// abctl produced no receipt at all. The tenant is as it was.
  ApplyState aborted({
    required SyncFailure failure,
    List<String> transcript = const <String>[],
    DateTime? at,
  }) => ApplyState(
    startedAt: startedAt,
    finishedAt: at,
    failure: failure,
    transcript: transcript,
  );

  /// Stopped mid-write. [result] stays null because there is none — that is exactly the problem.
  ApplyState wasInterrupted({
    required SyncFailure failure,
    required List<String> transcript,
    required DateTime at,
  }) => ApplyState(
    startedAt: startedAt,
    finishedAt: at,
    failure: failure,
    interrupted: true,
    transcript: transcript,
  );

  /// True when abctl positively established that a write did not reach Apple. Distinct from "not
  /// everything was checked": `--verify=none` checks nothing and is not a failure.
  bool get notPersisted =>
      result?.verification?.mismatches.any(
        (VerificationMismatch m) => m.observed,
      ) ??
      false;

  /// How many ITEMS failed: the larger of abctl's phase counters and the rows actually marked
  /// error. Where the two disagree, the count that HIDES a failure is the wrong one to print.
  ///
  /// Legitimately 0 on a failed run — a verdict-level failure fails the sync without failing any
  /// single item — so callers must branch on it rather than print it.
  int get failedCount {
    final ApplyResult? applied = result;
    if (applied == null) return 0;
    final int rows = applied.rows.where((OutcomeRow row) => row.failed).length;
    return applied.totalErrors > rows ? applied.totalErrors : rows;
  }

  /// The verdict, derived in ONE place so no widget can reach a different one.
  ApplyVerdict get verdict {
    if (isRunning) return ApplyVerdict.running;
    // Ahead of everything: an interrupted run may have written half the plan, and both branches
    // below would describe it as settled.
    if (interrupted) return ApplyVerdict.unknown;
    final ApplyResult? applied = result;
    if (applied != null) {
      // Any ONE of the three withholds the green verdict. The phase counters and the per-item
      // rows are two different numbers out of abctl, and the honest reading of a disagreement
      // between them is "something failed", never "all clear".
      return failure != null || applied.totalErrors > 0 || notPersisted
          ? ApplyVerdict.partial
          : ApplyVerdict.applied;
    }
    final SyncFailure? reason = failure;
    if (reason == null) return ApplyVerdict.idle;
    // abctl exited 0 and printed something abgui cannot read. It ran to completion, so claiming
    // nothing was applied would be a guess — and the wrong one to make.
    return reason.kind == SyncFailureKind.unreadable
        ? ApplyVerdict.unknown
        : ApplyVerdict.failed;
  }

  /// The run is over, however it ended — what turns the dialog's Cancel into Close.
  bool get isTerminal =>
      verdict != ApplyVerdict.idle && verdict != ApplyVerdict.running;

  /// True when abctl was actually STARTED for this state, as opposed to a pre-flight refusal
  /// that never spawned anything.
  ///
  /// The discriminator is [startedAt], and it is the only one available: a refusal is built from
  /// `const ApplyState()` (so its `startedAt` is null) while every transition of a real run —
  /// `finished`, `aborted`, `wasInterrupted` — carries forward the stamp `started` put there.
  /// [GitopsStore.applyPlan] needs the distinction because "this plan has already been applied,
  /// recompute before applying again" must not fire on a run that never happened; without it,
  /// one refusal (no workspace chosen, say) would lock the button for the rest of the session.
  bool get didRun => startedAt != null;

  @override
  bool operator ==(Object other) =>
      other is ApplyState &&
      other.isRunning == isRunning &&
      other.startedAt == startedAt &&
      other.finishedAt == finishedAt &&
      other.result == result &&
      other.failure == failure &&
      other.exitCode == exitCode &&
      other.interrupted == interrupted &&
      listEquals(other.transcript, transcript);

  @override
  int get hashCode => Object.hash(
    isRunning,
    startedAt,
    finishedAt,
    result,
    failure,
    exitCode,
    interrupted,
    transcript.length,
  );
}

/// The GitOps workspace: the directory CONTAINING `gitops/`, remembered across launches.
///
/// **Why the path is its own notifier rather than a field on [GitopsState].** Every client is
/// scoped by it — abctl resolves `gitops/` against its process working directory, so a verb run
/// from anywhere else reads a different tree, and the whole surface therefore runs with this as
/// cwd rather than adding one at each tree callsite. That makes the client depend on this value,
/// and [GitopsStore] depends on the client; holding the path inside the store's own state would
/// close that loop, which Riverpod asserts on and is right to. The two scoping values — this and
/// the active context — are leaves that depend on nothing, and that is what keeps the graph
/// acyclic while every store still reaches a properly scoped client.
class WorkspaceStore extends Notifier<String?> {
  /// Same key as the Swift app's `UserDefaults` entry, so a machine that ran both reopens the
  /// same folder.
  static const String key = 'abgui.workspacePath';

  @override
  String? build() => null;

  /// Reopen the last-used workspace. Called once at startup, through
  /// [GitopsStore.restoreWorkspace].
  ///
  /// A path that no longer exists is ignored rather than reported: a folder that moved is not an
  /// error the user needs a banner about, it is a folder they will pick again. A choice already
  /// made this session always wins — including one made DURING the await, which is why the check
  /// is repeated after it.
  Future<void> restore() async {
    if (state != null) return;
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final saved = prefs.getString(key);
      if (saved == null || saved.isEmpty) return;
      if (!Directory(saved).existsSync()) return;
      if (state != null) return;
      state = saved;
    } catch (_) {
      // Remembering is a convenience; a preferences store that will not open must not stop the
      // app from working with a folder the user picks by hand.
    }
  }

  /// Point at a folder and remember it. The DERIVED state (plan, report) is reset by
  /// [GitopsStore.setWorkspace], which is the only caller.
  Future<void> select(String path) async {
    state = path;
    try {
      final prefs = await ref.read(preferencesProvider.future);
      await prefs.setString(key, path);
    } catch (_) {
      // See restore(): failing to remember the choice must not fail the choice.
    }
  }
}

/// Everything read FROM the workspace. The path itself lives in [WorkspaceStore].
class GitopsState {
  const GitopsState({
    this.plan = const PlanState(),
    this.validation = const ValidationState(),
    this.seed = const SeedState(),
    this.apply = const ApplyState(),
    this.gitSourceOfTruth = true,
    this.refresh = AbctlRefresh.smart,
  });

  final PlanState plan;
  final ValidationState validation;

  /// The workspace-seeding run. Independent of [plan] for the same reason [validation] is: a seed
  /// hands off to a plan, and one busy flag between them is how the Swift screen got stuck.
  final SeedState seed;

  /// The last (or running) `sync --apply`. Empty until something has been applied this session.
  final ApplyState apply;

  /// Whether git is the complete desired state — for the plan AND for the write.
  ///
  /// **One switch, both verbs, and that is a safety property rather than a convenience.** `diff`
  /// is `sync --dry-run`: an operator who previews under git-as-truth and applies without it (or
  /// the reverse) has approved a plan that was never computed. [GitopsStore.applyPlan] therefore
  /// REFUSES an [ApplyOptions] whose mode disagrees with this flag instead of quietly running the
  /// other question's answer.
  ///
  /// On `diff` the flag only reverses which side counts as desired and writes nothing. Its twin
  /// on `sync --apply` implies removals — which is why the option that carries it is a named
  /// constructor on [ApplyOptions] rather than a boolean anything here can set.
  final bool gitSourceOfTruth;

  /// How much live state `diff` re-reads before it plans.
  final AbctlRefresh refresh;

  GitopsState copyWith({
    PlanState? plan,
    ValidationState? validation,
    SeedState? seed,
    ApplyState? apply,
    bool? gitSourceOfTruth,
    AbctlRefresh? refresh,
  }) => GitopsState(
    plan: plan ?? this.plan,
    validation: validation ?? this.validation,
    seed: seed ?? this.seed,
    apply: apply ?? this.apply,
    gitSourceOfTruth: gitSourceOfTruth ?? this.gitSourceOfTruth,
    refresh: refresh ?? this.refresh,
  );

  @override
  bool operator ==(Object other) =>
      other is GitopsState &&
      other.plan == plan &&
      other.validation == validation &&
      other.seed == seed &&
      other.apply == apply &&
      other.gitSourceOfTruth == gitSourceOfTruth &&
      other.refresh == refresh;

  @override
  int get hashCode =>
      Object.hash(plan, validation, seed, apply, gitSourceOfTruth, refresh);
}

/// The workspace, the plan, the verification report, the seed and the one command in this app
/// that changes a live Apple Business tenant.
///
/// **Four verbs, and the boundary between them is what a reader of this store has to trust.**
/// `diff` is `sync --dry-run` (live API calls, nothing written) and `validate` reads local files
/// with no credentials. `seed` READS the tenant and WRITES the local `gitops/` tree — no tenant
/// state changes, which is why `AbctlArgs.seed()` carries no `--yes`, but the workspace is
/// somebody's git checkout, so the destructive direction there is "over an existing tree" and
/// [SeedConsent] gates it.
///
/// [applyPlan] is the fourth, and it is different in kind: `sync --apply` creates, overwrites and
/// — when the options permit removals — DELETES configuration profiles belonging to a real
/// company. Three rules make that safe here, and each is enforced rather than documented:
///
///  * **The command comes from [ApplyOptions] and nothing else.** There is no boolean in this
///    file that can turn on a removal; the only input is the value type, whose constructors are
///    named for their consequences (`write_safety_test.dart`, invariant 1).
///  * **The write's mode must match the plan's.** [applyPlan] refuses an option value whose
///    git-source-of-truth setting disagrees with [GitopsState.gitSourceOfTruth], because the rows
///    on screen were computed under that setting and approving them approves nothing else.
///  * **Success is the receipt, never the exit code.** The client decodes stdout before it maps
///    the exit status, and [ApplyState.verdict] is the single place that reads the two together
///    (invariant 6).
class GitopsStore extends Notifier<GitopsState> {
  /// FOUR generations, and the split is the whole lesson of `LoadGeneration`: computing a plan,
  /// verifying the profiles, seeding the tree and applying are independent operations a user can
  /// start in any order, and one shared counter means whichever finishes second finds its token
  /// invalidated and its spinner stuck. The seed/plan pair is not a hypothetical — that exact
  /// sharing left the Swift Diff screen on "Initializing workspace from the tenant…" with every
  /// control disabled, unrecoverable without a relaunch.
  final LoadGeneration _plans = LoadGeneration('gitops.plan');
  final LoadGeneration _validations = LoadGeneration('gitops.validate');
  final LoadGeneration _seeds = LoadGeneration('gitops.seed');
  final LoadGeneration _applies = LoadGeneration('gitops.apply');

  /// The in-flight plan's kill switch, so the Cancel button can terminate the abctl child.
  CancelToken? _planCancel;

  /// The in-flight seed's. Separate from [_planCancel] because a seed HANDS OFF to a plan: for the
  /// last part of a seed both are live, and one shared token would have the seed's own Cancel kill
  /// the plan it started while leaving nothing to report about the seed.
  CancelToken? _seedCancel;

  /// The in-flight apply's. Its own token for a blunter reason than the others: this is the one
  /// cancel in the app that stops a run PART WAY THROUGH WRITING, and what it leaves behind has to
  /// be reported as unknown rather than as failed. Sharing a token with the plan would let a
  /// Cancel meant for a diff kill a tenant write instead.
  CancelToken? _applyCancel;

  /// The open run log, or null. At most one: this store runs one workspace verb at a time — a seed
  /// and the plan it hands off to are ONE operation and share a single file.
  RunLog? _runLog;

  /// The exact [Plan] object the last apply was launched against, held by IDENTITY.
  ///
  /// Not a copy and not a hash: the question rule 5 in [applyPlan] asks is "is the plan on screen
  /// the same object I already applied", and a value comparison would answer yes for a recomputed
  /// plan that happens to be unchanged — which is a plan an operator is entitled to apply again.
  /// Null until an apply starts, and cleared by [setWorkspace] with the rest of the derived state.
  Plan? _appliedPlan;

  @override
  GitopsState build() => const GitopsState();

  /// True while a plan is being computed — the only thing the Cancel button needs to know.
  bool get canCancel => _planCancel != null;

  /// True while anything in this store has an abctl child to kill. The shell's run strip asks
  /// this rather than [canCancel]: during a seed there is no plan, and a Cancel that quietly does
  /// nothing is worse than no Cancel at all.
  bool get canCancelWork =>
      _planCancel != null || _seedCancel != null || _applyCancel != null;

  /// The chosen workspace, or null. Read from [WorkspaceStore] at call time rather than mirrored
  /// here, so there is exactly one answer to "which folder are we in" for the store and for the
  /// client that runs in it.
  String? get workspace => ref.read(workspaceProvider);

  /// Reopen the last-used workspace at startup. Nothing is computed from it — the screen that
  /// wants a plan asks for one.
  Future<void> restoreWorkspace() =>
      ref.read(workspaceProvider.notifier).restore();

  /// Point at a GitOps workspace and start over.
  ///
  /// Everything derived from the previous folder goes: the plan, the report, both stamps and both
  /// error slots. Carrying a green "Verified" row over to files nobody has checked is the version
  /// of this bug that matters. The in-flight plan is both CANCELLED (its abctl child is reading
  /// the old tree) and orphaned, so it cannot publish into the new folder's state as it unwinds.
  Future<void> setWorkspace(String path) async {
    _plans.invalidate();
    _validations.invalidate();
    _seeds.invalidate();
    _applies.invalidate();
    _planCancel?.cancel();
    _planCancel = null;
    // An apply writes the TENANT, and it was started against the tree that is being navigated away
    // from. Letting it run on would have a live write finish with no screen in the app able to
    // report its receipt — the exact "did that land?" state this store exists to never produce.
    _applyCancel?.cancel();
    _applyCancel = null;
    // A seed writes FILES, and it writes them into the folder it was started in. Leaving one
    // running while the user points the app somewhere else would have an abctl child filling the
    // previous workspace's tree with no screen in the app saying so.
    _seedCancel?.cancel();
    _seedCancel = null;
    // Part of the derived state, and it has to be dropped with it: the new workspace's first plan
    // is a different object anyway, but leaving a pointer at the old tree's plan is a dangling
    // fact in a store whose whole job is to know which tree it is talking about.
    _appliedPlan = null;
    ref.read(progressSinkProvider).clear();
    state = GitopsState(
      gitSourceOfTruth: state.gitSourceOfTruth,
      refresh: state.refresh,
    );
    await ref.read(workspaceProvider.notifier).select(path);
  }

  /// Flip which side `diff` treats as the desired state.
  ///
  /// The computed plan is DROPPED, not kept: it answers the question the other mode asked, and a
  /// plan sitting under a switch that now says something else is a lie whichever way it is read.
  /// Recomputing is the caller's move — the control that flips this also owns the confirmation.
  void setGitSourceOfTruth(bool enabled) {
    if (enabled == state.gitSourceOfTruth) return;
    _plans.invalidate();
    _planCancel?.cancel();
    _planCancel = null;
    state = state.copyWith(gitSourceOfTruth: enabled, plan: const PlanState());
  }

  /// How much live state the next plan re-reads. The plan on screen stays: this changes what the
  /// next run COSTS, not what a plan means.
  void setRefresh(AbctlRefresh refresh) {
    if (refresh == state.refresh) return;
    state = state.copyWith(refresh: refresh);
  }

  /// Terminate the in-flight plan's abctl child. Safe when nothing is running.
  void cancelPlan() {
    _planCancel?.cancel();
  }

  /// Terminate whatever workspace verb is running — the plan, the seed, or both during the
  /// hand-off. Safe when nothing is running.
  ///
  /// Cancelling a seed leaves a HALF-WRITTEN tree, which is the one thing that separates it from
  /// cancelling a plan and the reason the Cancel affordance says so: abctl has been writing files
  /// into `gitops/` as it went, and stopping it mid-download leaves a directory that is neither
  /// the old tree nor a complete one. Re-seeding is the fix, and the next `diff` will show the
  /// gap either way.
  void cancelWork() {
    _planCancel?.cancel();
    _seedCancel?.cancel();
    _applyCancel?.cancel();
  }

  /// Terminate the in-flight `sync --apply`. Safe when nothing is running.
  ///
  /// **What this does NOT do is undo anything.** abctl writes configuration by configuration, so
  /// stopping it mid-run leaves whatever it had already pushed to Apple in place, with no receipt
  /// to say which items those were. [ApplyState.interrupted] is how that reaches the screen, and
  /// it is deliberately not the same state as a failure.
  void cancelApply() {
    _applyCancel?.cancel();
  }

  /// Drop the seed's summary once the user has read it. The stamp survives.
  void dismissSeedSummary() {
    if (state.seed.summary == null && state.seed.error == null) return;
    state = state.copyWith(seed: state.seed.dismissed());
  }

  /// Initialize (or re-initialize) the workspace's `gitops/` tree from live tenant state, then
  /// compute drift against what was just written. Returns true on a clean seed.
  ///
  /// This is what turns a plain folder into a GitOps workspace from inside the app — the one verb
  /// here that puts files on disk. It reads the tenant and writes LOCAL files only, so nothing
  /// about Apple Business changes and there is no tenant gate to pass; what there IS to protect is
  /// the folder, which is why [consent] exists and why the refusal below is the store's and not a
  /// dialog's. A screen that forgets to ask gets an error message, not a rewritten checkout.
  ///
  /// **abctl's answer is prose.** `seed` prints human text, not a document, so the summary is
  /// carried through verbatim and nothing decodes it — see [SeedState].
  ///
  /// **The seed and its plan are ONE operation.** The transcript is not reset between them and the
  /// run log is not reopened, so the `$ abctl seed` / `→ exit 0` lines the user just watched
  /// scroll by are still there when the diff's lines arrive underneath. Clearing at the hand-off
  /// would erase the command the moment it finished, in the pane whose whole job is to show that
  /// something is happening.
  Future<bool> seedWorkspace({required SeedConsent consent}) async {
    final workspace = this.workspace;
    if (workspace == null) {
      state = state.copyWith(
        seed: state.seed.failed(
          'Choose a GitOps workspace folder first — seeding downloads the live tenant into that '
          'folder\'s gitops/ tree, and abctl resolves that tree against the directory it runs in.',
        ),
      );
      return false;
    }
    // Never during an apply, for the reason spelled out in [refreshPlan]: a seed clears the shared
    // transcript and takes over the run log, and the log it would take over is the receipt for a
    // command that is at that moment writing to Apple Business. A seed is worse than a plan here —
    // it also REWRITES gitops/ from the tenant while abctl is reconciling against that same tree.
    if (state.apply.isRunning) {
      state = state.copyWith(
        seed: state.seed.failed(
          'An apply is writing to Apple Business right now, against this workspace\'s gitops/ '
          'tree. Seeding would rewrite that tree underneath it. Wait for the apply to finish, or '
          'stop it, before seeding.',
        ),
      );
      return false;
    }
    // The guard, and it is deliberately a REFUSAL rather than a prompt: this layer has no way to
    // ask, and a store that seeded anyway "because the caller surely confirmed" is a store whose
    // safety depends on every future callsite remembering.
    if (consent == SeedConsent.onlyIfAbsent && hasGitopsTree(workspace)) {
      state = state.copyWith(
        seed: state.seed.failed(
          'This folder already has a gitops/ tree. Seeding rewrites it from whatever Apple '
          'Business has right now, which discards local edits that have not been synced. '
          'Re-seed explicitly if that is what you want.',
        ),
      );
      return false;
    }

    final token = _seeds.begin();
    final cancel = CancelToken();
    _seedCancel = cancel;
    final sink = ref.read(progressSinkProvider);
    // Before the first line of this run, for the reason `refreshPlan` clears here too: the
    // recorder emits `$ abctl seed` from inside the call below, and a clear afterwards would wipe
    // the command the user just watched appear.
    sink.clear();
    state = state.copyWith(seed: state.seed.started());

    final log = await _openRunLog(
      workspace,
      verb: RunLogVerb.seed,
      base: AbctlArgs.seed(),
    );
    var outcome = 'workspace initialized';
    var seeded = false;
    try {
      final summary = await ref
          .read(narratingClientProvider)
          .seed(cancel: cancel);
      if (token.isStale) {
        outcome = 'superseded by a newer seed';
      } else {
        state = state.copyWith(
          seed: state.seed.succeeded(summary, DateTime.now()),
        );
        seeded = true;
      }
    } on AbctlCancelled {
      outcome = 'cancelled — the tree may be half written';
      if (!token.isStale) {
        state = state.copyWith(seed: state.seed.settled());
      }
    } catch (error) {
      if (token.isStale) {
        outcome = 'superseded by a newer seed';
      } else {
        final text = loadErrorText(error);
        outcome = 'failed — $text';
        state = state.copyWith(seed: state.seed.failed(text));
      }
    } finally {
      // Publish the buffered tail before anything reads it, so a failure is diagnosed from the
      // last thing abctl actually printed.
      sink.flush();
      if (identical(_seedCancel, cancel)) _seedCancel = null;
    }

    // The hand-off. Only on success, and only while this seed is still the current one: a
    // superseded run must not start a plan for a workspace somebody has already navigated away
    // from, and a failed seed has nothing new to diff against.
    if (seeded && !token.isStale) {
      await refreshPlan(resetTranscript: false, newRunLog: false);
    }
    // Only the call that OPENED the log closes it, and only while it still owns the run — the
    // same rule `refreshPlan` follows, which is also why the plan above was told not to close it.
    if (log != null && identical(_runLog, log)) {
      await _finishRunLog(outcome);
    }
    return seeded;
  }

  /// Compute the 3-way plan: what a reconcile WOULD change, written nowhere.
  ///
  /// Narrated: this is the one verb slow enough to need live output, so it runs through the
  /// narrating client and its stderr streams into the coalescing [ProgressSink] (which is not a
  /// provider, on purpose — see `progress_sink.dart`).
  ///
  /// [resetTranscript] and [newRunLog] default to true — a plan the user asked for is its own
  /// operation and owns both. [seedWorkspace] passes false for both because its plan is the second
  /// HALF of one operation: one transcript, one log file, closed by the seed that opened it.
  Future<void> refreshPlan({
    bool resetTranscript = true,
    bool newRunLog = true,
  }) async {
    final workspace = this.workspace;
    if (workspace == null) {
      state = state.copyWith(
        plan: state.plan.failed(
          'Choose a GitOps workspace folder first — the folder that contains gitops/. '
          'abctl resolves that tree against the directory it runs in, so a diff without one '
          'would plan against wherever the app happened to be launched from.',
        ),
      );
      return;
    }
    // Fast pre-flight: a folder with no gitops/ is not a workspace yet, and finding that out
    // costs a `stat` here versus a full network diff that has nothing to compare against.
    if (!hasGitopsTree(workspace)) {
      state = state.copyWith(plan: state.plan.needsTree());
      return;
    }
    // **Never during an apply.** A plan and an apply share one [ProgressSink] and one run log, and
    // starting a plan here is not a harmless overlap: `sink.clear()` below wipes the apply's live
    // transcript, `_openRunLog` closes the apply's log stamped "superseded by a new run", and the
    // apply's own `finally` then skips its footer because `identical(_runLog, log)` has become
    // false. The apply would go on to snapshot `sink.lines.value` — by then the PLAN's narration —
    // into `ApplyState.transcript` and hand it to `SyncFailure.fromApplyResult`, filing another
    // command's output as the receipt for a live tenant write.
    //
    // Today no screen can reach this (`ApplyDialog` is app-modal and the Diff toolbar disables
    // every control on `plan || seed || apply`), which is exactly why it belongs here: the
    // transcript of a tenant write must not depend on a dialog staying modal. Plan-supersedes-plan
    // is NOT refused — that is what `_plans` exists for and is a deliberate behaviour.
    if (state.apply.isRunning) {
      state = state.copyWith(
        plan: state.plan.failed(
          'An apply is writing to Apple Business right now. Its narration and its run log are '
          'the record of that write, and computing a plan would overwrite both. Wait for it to '
          'finish, or stop it, and then refresh.',
        ),
      );
      return;
    }

    final token = _plans.begin();
    final cancel = CancelToken();
    _planCancel = cancel;
    final sink = ref.read(progressSinkProvider);
    // Reset the transcript BEFORE the first line of this run: the recorder emits `$ abctl diff …`
    // from inside the call below, and a clear that happened after it would wipe the command the
    // user just watched appear. The seed's hand-off skips it entirely — see [seedWorkspace].
    if (resetTranscript) sink.clear();
    state = state.copyWith(plan: state.plan.started());

    // Null when the caller owns the log. `_openRunLog` is what points the sink's mirror at a file,
    // so NOT calling it is also what keeps this plan's narration flowing into the seed's log
    // rather than into a second one nobody is watching.
    final log = newRunLog
        ? await _openRunLog(
            workspace,
            verb: RunLogVerb.diff,
            base: AbctlArgs.plan(
              gitSourceOfTruth: state.gitSourceOfTruth,
              refresh: state.refresh,
            ),
          )
        : null;
    var outcome = 'plan computed';
    try {
      final computed = await ref
          .read(narratingClientProvider)
          .plan(
            gitSourceOfTruth: state.gitSourceOfTruth,
            refresh: state.refresh,
            cancel: cancel,
          );
      // A superseded run must not publish its plan: it was computed for the previous mode or the
      // previous workspace, and showing it beside the current one is the lie this token exists to
      // prevent.
      if (token.isStale) {
        outcome = 'superseded by a newer plan';
        return;
      }
      state = state.copyWith(
        plan: state.plan.succeeded(computed, DateTime.now()),
      );
    } on AbctlCancelled {
      outcome = 'cancelled';
      if (!token.isStale) {
        state = state.copyWith(plan: state.plan.settled());
      }
    } on AbctlChangesPending {
      // Exit 3 means drift, which is a NORMAL verdict and must never be rendered as a failure.
      // This release never passes `--exit-on-diff`, so reaching here means abctl reported drift
      // without printing the plan we asked for — nothing to render, but not nothing to say.
      outcome = 'changes pending, no plan printed';
      if (!token.isStale) {
        state = state.copyWith(
          plan: state.plan.noted(
            'abctl reported changes pending but printed no plan. Run `abctl diff --json` in the '
            'workspace to see the drift it found.',
          ),
        );
      }
    } catch (error) {
      if (token.isStale) {
        outcome = 'superseded by a newer plan';
      } else {
        final text = loadErrorText(error);
        outcome = 'failed — $text';
        state = state.copyWith(plan: state.plan.failed(text));
      }
    } finally {
      // Publish the buffered tail before the log is closed, so the file ends with the last thing
      // abctl printed rather than with a footer written over lines still sitting in the buffer.
      sink.flush();
      if (identical(_planCancel, cancel)) _planCancel = null;
      // Only the call that OPENED a log closes it, and only while it still owns the run: a
      // superseded run that closed the log would close its SUCCESSOR's — stamping the file the
      // user is watching as "cancelled" and dropping every line the live run had left to write.
      if (log != null && identical(_runLog, log)) {
        await _finishRunLog(outcome);
      }
    }
  }

  /// Reconcile the live tenant to the workspace's git desired state: `sync --apply`.
  ///
  /// **The only command in this app that changes another company's Apple Business
  /// configuration.** Five things guard it, and all five are here rather than in the dialog that
  /// calls it — a store whose safety depends on every future caller remembering is not guarded at
  /// all:
  ///
  ///  1. **[options] is the whole command.** `--prune` is derived inside `AbctlArgs.syncApply`
  ///     from the option value's constructor and is not a parameter anywhere on this path.
  ///  2. **The mode must match the plan on screen.** `diff` and `sync --apply` take the same
  ///     git-source-of-truth flag; applying under the other setting executes a plan nobody
  ///     computed, so it is REFUSED rather than run.
  ///  3. **`--refresh=metadata-only` is refused before it reaches abctl.** abctl rejects that
  ///     combination outright (`internal/cli/phase1.go`: metadata-only never fetches profile XML,
  ///     which every write needs in order to archive, pull or prune) — and a refusal that costs a
  ///     process spawn and a stderr blob reads to the operator as "apply is broken".
  ///  4. **One workspace verb at a time.** A plan, a seed and an apply share one transcript and
  ///     one run log; two at once produce a file that describes neither.
  ///  5. **The verdict is the receipt.** stdout is decoded before the exit code is judged (see
  ///     `AbctlClient.syncApply`), the two are kept together, and [ApplyState.verdict] is the one
  ///     place that reads them.
  ///
  /// Narrated, like the plan: an apply against a real tenant is minutes of per-configuration
  /// stderr, and silence during it is indistinguishable from a hang.
  Future<void> applyPlan(ApplyOptions options) async {
    final workspace = this.workspace;
    if (workspace == null) {
      _refuseApply(
        'Choose a GitOps workspace folder first — the folder that contains gitops/. abctl '
        'resolves that tree against the directory it runs in, so an apply without one would '
        'reconcile the tenant against whatever tree happened to be beside the app.',
      );
      return;
    }
    if (!hasGitopsTree(workspace)) {
      _refuseApply(
        'There is no gitops/ tree in this folder, so there is no desired state to apply. Seed '
        'the workspace first.',
      );
      return;
    }
    // Rule 2. Both halves are stated, because "they disagree" is not actionable on its own.
    if (options.gitSourceOfTruth != state.gitSourceOfTruth) {
      _refuseApply(
        'The plan on screen was computed with git as the source of truth '
        '${state.gitSourceOfTruth ? 'ON' : 'OFF'}, and this command would apply it with that '
        'setting ${options.gitSourceOfTruth ? 'ON' : 'OFF'}. Those are different reconciles: '
        'applying one against the other\'s plan would execute changes nobody reviewed. Recompute '
        'the plan first.',
      );
      return;
    }
    // Rule 3.
    if (options.refresh == AbctlRefresh.metadataOnly) {
      _refuseApply(
        'A metadata-only refresh cannot be applied: it never fetches profile XML, and every '
        'write needs those bytes to archive the live version before overwriting or deleting it. '
        'abctl refuses this combination. Use the smart or full refresh.',
      );
      return;
    }
    // Rule 4, first half, and it returns SILENTLY on purpose.
    //
    // `_refuseApply` publishes `const ApplyState().aborted(...)` — isRunning:false,
    // startedAt:null, interrupted:false — which is right for a refusal of an apply that never
    // started and catastrophic for this one, because the apply being refused here is the one
    // still writing to the tenant. Publishing it while `abctl sync --apply --yes --prune` is
    // mid-flight made the dialog render "Nothing was applied" over a live write, re-enabled
    // Escape (`PopScope(canPop: !apply.isRunning)`), and removed the Cancel button — the only
    // control in the app that reaches `_applyCancel` — for the rest of the run. The running
    // state IS the answer to a second press: the header already says "Applying…" with a live
    // elapsed reading beside it, so there is nothing to report and everything to lose.
    if (state.apply.isRunning) return;
    // Rule 4, second half. No apply is in flight here, so a refusal has nothing to overwrite.
    if (state.plan.isRunning || state.seed.isRunning) {
      _refuseApply(
        'Another abctl command is already running in this workspace. Wait for it to finish, or '
        'stop it, before applying.',
      );
      return;
    }
    // Rule 5. **One apply per plan, enforced HERE and not only by a disabled button.**
    //
    // The dialog disables Apply once the run reaches a terminal outcome, but that is a property
    // of a rebuilt frame: two activations of the captured `onPressed` closure — a double-click,
    // an accessibility `activate`, a synthesized tap — reached this method twice from one typed
    // confirmation and ran `sync --apply` twice against the tenant. `create config` has had the
    // equivalent guard since it shipped (`config_editor_dialog._canWrite`); the one verb that
    // can DELETE production profiles had none, which contradicts this store's own rule that a
    // store whose safety depends on every future caller remembering is not guarded at all.
    //
    // The identity of the `Plan` object is what makes "again" checkable without erasing the
    // receipt the operator is still reading: `refreshPlan` publishes a NEW `Plan`, so a
    // recompute re-arms the button by itself, while `supersededByApply()` only sets a flag on
    // `PlanState` and leaves the plan it describes the same object. `didRun` keeps a pre-flight
    // refusal — which never touched `_appliedPlan` — from counting as an apply.
    if (state.apply.didRun &&
        state.apply.isTerminal &&
        identical(_appliedPlan, state.plan.plan)) {
      _refuseApply(
        'This plan has already been applied. The counts you approved describe the tenant as it '
        'was BEFORE that run, so applying them again would execute numbers that are no longer '
        'true. Recompute the plan first.',
      );
      return;
    }

    final token = _applies.begin();
    // Claimed before the first await, beside the generation, so a second activation inside the
    // same frame is measured against it rather than against a field a later frame will set.
    _appliedPlan = state.plan.plan;
    final cancel = CancelToken();
    _applyCancel = cancel;
    final sink = ref.read(progressSinkProvider);
    // Before the first line, for the reason the plan clears here: the recorder emits
    // `$ abctl sync --apply …` from inside the call below, and a clear afterwards would wipe the
    // one line on screen that says what is being run.
    sink.clear();
    state = state.copyWith(apply: state.apply.started(DateTime.now()));

    final log = await _openRunLog(
      workspace,
      verb: RunLogVerb.sync,
      base: AbctlArgs.syncApply(options),
    );
    var outcome = 'applied';
    try {
      final run = await ref
          .read(narratingClientProvider)
          .syncApply(options, cancel: cancel);
      // Publish the buffered tail BEFORE the transcript is snapshotted: the last lines abctl
      // printed are usually the verdict, and a snapshot taken over an unflushed buffer is a
      // failure report missing its own explanation.
      sink.flush();
      if (token.isStale) {
        outcome = 'superseded — the workspace changed while it ran';
        return;
      }
      // nil ⇔ every item succeeded AND abctl exited 0. This IS the pass/fail test, not a second
      // condition beside one: a receipt full of `done` rows accompanied by a non-zero exit is a
      // run whose writes Apple did not persist, and only this call knows that.
      final failure = SyncFailure.fromApplyResult(
        run.result,
        exitCode: run.code,
        stderr: run.stderr,
        transcript: sink.lines.value,
      );
      state = state.copyWith(
        apply: state.apply.finished(
          applied: run.result,
          code: run.code,
          failure: failure,
          transcript: sink.lines.value,
          at: DateTime.now(),
        ),
        // Only when something actually landed. A run that wrote nothing leaves the plan true, and
        // a "recompute me" banner over rows that are still accurate is noise that teaches the
        // reader to ignore the banner that matters.
        plan: run.result.totalWrites > 0
            ? state.plan.supersededByApply()
            : state.plan,
      );
      outcome = failure == null
          ? 'succeeded: ${run.result.totalWrites} write(s), '
                '${run.result.totalSkipped} skipped'
          : 'failed — ${failure.headline}';
    } catch (error) {
      sink.flush();
      if (token.isStale) {
        outcome = 'superseded — the workspace changed while it ran';
        return;
      }
      final failure = _applyFailure(error, sink.lines.value);
      // The two ways an apply ends without a receipt are NOT the same situation. A cancel or a
      // watchdog kill stops abctl part way through writing; anything else means it never got as
      // far as applying, so the tenant is untouched and the plan on screen still describes it.
      final stoppedMidWrite = error is AbctlCancelled || error is AbctlTimedOut;
      outcome = stoppedMidWrite
          ? 'stopped mid-apply — what landed is unknown'
          : 'failed — ${failure.headline}';
      state = state.copyWith(
        apply: stoppedMidWrite
            ? state.apply.wasInterrupted(
                failure: failure,
                transcript: sink.lines.value,
                at: DateTime.now(),
              )
            : state.apply.aborted(
                failure: failure,
                transcript: sink.lines.value,
                at: DateTime.now(),
              ),
        plan: stoppedMidWrite ? state.plan.supersededByApply() : state.plan,
      );
    } finally {
      sink.flush();
      if (identical(_applyCancel, cancel)) _applyCancel = null;
      // Only the call that OPENED a log closes it, and only while it still owns the run — the
      // same rule the plan and the seed follow.
      if (log != null && identical(_runLog, log)) {
        await _finishRunLog(outcome);
      }
    }
  }

  /// Report a pre-flight refusal as the failed outcome of an apply that never started.
  ///
  /// Routed through [SyncFailure] rather than a bare string so the dialog has ONE thing to
  /// render: a refusal and an abctl abort are the same shape to a reader — "it did not run, here
  /// is why" — and giving them two shapes means two ways for a message to go missing.
  ///
  /// **It refuses to speak over a running apply, and that guard is structural rather than a note
  /// to callers.** Every state this builds is derived from `const ApplyState()`, so publishing
  /// one while abctl is mid-write replaces a live run with `isRunning:false, startedAt:null` —
  /// "Nothing was applied", stated positively, over a command that is at that moment deleting
  /// configuration profiles. [applyPlan] already orders its guards so this cannot happen; the
  /// check is repeated here because the next refusal someone adds will not know that.
  void _refuseApply(String reason) {
    if (state.apply.isRunning) return;
    state = state.copyWith(
      apply: const ApplyState().aborted(
        failure: SyncFailure.fromError(reason),
        at: DateTime.now(),
      ),
    );
  }

  /// Verify the workspace's own profiles and the blueprint references that point at them.
  ///
  /// Local files only: no tenant call, no credentials, which makes it the one verb that works
  /// before a connection exists. Returns true when the report is clean. Runs through the SILENT
  /// client — it prints no narration worth streaming, and opening a run log for it would repoint
  /// "the last run log" away from the diff whose failure is still on screen.
  Future<bool> validate() async {
    if (workspace == null) {
      state = state.copyWith(
        validation: state.validation.failed(
          'Choose a GitOps workspace folder first — validate reads that folder\'s gitops/ tree.',
        ),
      );
      return false;
    }
    final token = _validations.begin();
    state = state.copyWith(validation: state.validation.started());
    try {
      final report = await ref.read(abctlClientProvider).validateProfiles();
      if (token.isStale) return false;
      state = state.copyWith(
        validation: state.validation.succeeded(report, DateTime.now()),
      );
      return report.ok;
    } on AbctlCancelled {
      if (!token.isStale) {
        state = state.copyWith(validation: state.validation.settled());
      }
      return false;
    } catch (error) {
      if (token.isStale) return false;
      state = state.copyWith(
        validation: state.validation.failed(loadErrorText(error)),
      );
      return false;
    }
  }

  /// True when `<root>/gitops/` exists and is a directory — abctl's tree root.
  static bool hasGitopsTree(String root) {
    final separator = Platform.pathSeparator;
    final trimmed = root.endsWith(separator)
        ? root.substring(0, root.length - separator.length)
        : root;
    return Directory('$trimmed${separator}gitops').existsSync();
  }

  /// Open the on-disk transcript for this run, closing any previous one first.
  ///
  /// The header's command comes from the same pure builder the run itself uses, threaded through
  /// `AbctlClient.previewArgv` so it carries the same `--context` tail — the file names the command
  /// that actually executed. It is laundered through [CommandRecord], which REDACTS in its
  /// constructor, so no callsite can hand a secret-bearing argv to the log.
  ///
  /// **It cannot fail the plan.** `RunLog.begin` answers null on any trouble (no directory, a
  /// read-only disk, a sandbox denial) rather than throwing, and the whole body is wrapped anyway
  /// because the opener is an injectable seam and a plan that died because a LOG could not be
  /// written would be the worst possible trade.
  ///
  /// [base] is the run's own pure argv, passed IN rather than rebuilt here: the header has to name
  /// the command that executed, and a log that spelled `diff` for every verb because that is what
  /// this method happened to hard-code would be a transcript of a run that never happened.
  Future<RunLog?> _openRunLog(
    String workspace, {
    required RunLogVerb verb,
    required List<String> base,
  }) async {
    try {
      // Belt and braces: a run that somehow never reached its finish would otherwise hold an open
      // handle and leave a footerless file, which is the signal reserved for "the app died".
      await _finishRunLog('superseded by a new run');
      final status = ref.read(connectionProvider);
      final version = status is ConnectionConnected ? status.version : null;
      final argv = ref.read(narratingClientProvider).previewArgv(base);
      final redacted = CommandRecord(argv: argv, cwd: workspace);
      final log = await ref.read(runLogOpenerProvider)(
        RunLogHeader(
          verb: verb,
          command: redacted.commandLine,
          workspace: workspace,
          context: ref.read(activeContextProvider),
          abctlVersion: version?.version,
          abctlCommit: version?.commit,
          abguiVersion: ref.read(abguiVersionProvider),
          stdin: redacted.stdin,
        ),
      );
      _runLog = log;
      // The mirror is a stable method reference over the store's CURRENT log rather than a tear-off
      // of this particular one: a run that supersedes another must not leave the sink writing lines
      // into a file its predecessor has already closed.
      ref.read(progressSinkProvider).mirror = _mirrorLine;
      return log;
    } catch (_) {
      _runLog = null;
      return null;
    }
  }

  void _mirrorLine(String line) => _runLog?.line(line);

  /// Also non-throwing, for the same reason: this runs in [refreshPlan]'s `finally`, where an
  /// exception would replace the plan's own outcome with a filesystem complaint.
  Future<void> _finishRunLog(String outcome) async {
    final log = _runLog;
    if (log == null) return;
    _runLog = null;
    try {
      await log.finish(outcome: outcome);
    } catch (_) {
      // The transcript is already as complete as it is going to get.
    }
  }
}

/// Classify an apply that threw, into the one type the UI renders.
///
/// **A switch over the sealed [AbctlError] family, not a chain of `is` tests, and that is the
/// point of the family being sealed:** a future abctl failure mode added to it breaks this build
/// instead of falling into the catch-all and being reported to an operator as "Sync failed." over
/// a tenant that is in some other state entirely. Each branch hands [SyncFailure] the inputs its
/// matching factory was written for — the classification rules live there, once, and are tested
/// against real captured stderr without a process or a tenant.
///
/// [transcript] is abgui's own narration, used only where abctl left nothing else behind.
SyncFailure _applyFailure(
  Object error,
  List<String> transcript,
) => switch (error) {
  AbctlCancelled() => SyncFailure.fromCancellation(transcript: transcript),
  // The long "here is what a timeout usually means" paragraph is the DETAIL; the headline
  // only has to say the run was stopped and after how long.
  AbctlTimedOut(:final int seconds, :final String message) =>
    SyncFailure.fromTimeout(
      seconds: seconds,
      description: message,
      transcript: transcript,
    ),
  // Exit 1 with no receipt: abctl already explained itself on stderr, and mining that beats
  // anything abgui could paraphrase.
  AbctlCliError(:final String stderr) => SyncFailure.fromAbort(
    stderr: stderr,
    transcript: transcript,
  ),
  // Exit 2: abctl did not understand the command abgui built. Still mine stderr (it names the
  // bad flag), but say whose bug it is.
  AbctlUsageError(:final String stderr) => SyncFailure.fromUsageRejection(
    stderr: stderr,
    transcript: transcript,
  ),
  AbctlDecodeError(:final String message) => SyncFailure.fromDecodeFailure(
    description: message,
    transcript: transcript,
  ),
  // Exit 3 from `--apply` means the flags were wrong: it is the dry-run signal.
  AbctlChangesPending(:final String message) => SyncFailure.fromChangesPending(
    description: message,
    transcript: transcript,
  ),
  // Its message carries every path that was searched, which for a packaging bug is the whole
  // diagnosis — so it is passed through whole rather than summarized.
  AbctlMissingBinary(:final String message) => SyncFailure.fromError(
    message,
    transcript: transcript,
  ),
  _ => SyncFailure.fromError(loadErrorText(error), transcript: transcript),
};
