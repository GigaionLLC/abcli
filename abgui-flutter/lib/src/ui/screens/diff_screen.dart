// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/models/plan.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/dialogs/apply_dialog.dart';
import 'package:abgui/src/ui/dialogs/seed_dialog.dart';
import 'package:abgui/src/ui/dialogs/validate_dialog.dart';
import 'package:abgui/src/ui/text_labels.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/copy_button.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// The GitOps hero screen: `abctl diff --json` rendered as a reviewable plan.
///
/// **What a reader of this screen has to be able to answer, in order:** is anything going to be
/// deleted, how much is going to change, and what exactly. Everything below is arranged around
/// that ordering — the summary counts by CONSEQUENCE rather than by row (see [PlanConsequence]),
/// the table sorts destructive rows to the top, and each row carries its consequence twice: once
/// as the stripe down its edge and once as the word inside its action pill, so the answer
/// survives a screenshot, a projector and a reader with no colour vision.
///
/// **Apply is armed, and this screen is not where it is gated.** The toolbar's Apply opens
/// [ApplyDialog] and nothing more: the counts, the exact command, the removal warning and the
/// typed confirmation all live there, in front of the write, where an operator is deciding rather
/// than browsing. What this screen owes that decision is an accurate plan — which is why the only
/// thing added here besides the control is the banner that says when the rows are no longer one
/// ([PlanState.superseded]).
class DiffScreen extends ConsumerStatefulWidget {
  const DiffScreen({super.key});

  @override
  ConsumerState<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends ConsumerState<DiffScreen> {
  /// The row whose full detail the strip under the table is showing.
  ///
  /// A table row is one fixed-height line, so abctl's `detail` sentence — the half of a plan row
  /// that says WHY — is ellipsised in the cell. Selecting a row promotes that sentence into a
  /// strip that can wrap it. Selection is the only interaction on this table, deliberately: a
  /// plan is applied whole or not at all (abctl has no way to execute a subset of one), so a row
  /// that could be checked or actioned would promise something the command cannot do. What a
  /// reader needs from a row is to be able to point at it and read it in full.
  PlanRow? _focused;

  /// The flattened plan, cached against the [Plan] it was derived from.
  ///
  /// Selecting a row rebuilds this screen, and a fresh row list on every build is a list `AbTable`
  /// cannot recognize as the same one — it re-filters and re-sorts on identity. That is the exact
  /// cost its own cached `_display` exists to avoid, so it must not be handed a new list per
  /// click. The store replaces a `Plan` wholesale and never mutates one, which is what makes
  /// identity the right test here.
  Plan? _rowsSource;
  List<PlanRow> _rows = const <PlanRow>[];

  List<PlanRow> _rowsFor(Plan? plan) {
    if (!identical(plan, _rowsSource)) {
      _rowsSource = plan;
      _rows = PlanRow.of(plan);
    }
    return _rows;
  }

  @override
  void initState() {
    super.initState();
    // NOT called inline. Everything below reaches abctl, and every abctl run is recorded into
    // `commandLogProvider` by `RecordingRunner.onStart` — synchronously, before its first await.
    // Riverpod throws "tried to modify a provider while the widget tree was building" for that,
    // so the first command of the session has to start after this frame rather than during it.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_bootstrap()),
    );
  }

  /// Reopen the remembered workspace and, if there is one, compute the plan for it.
  ///
  /// Restoring here as well as at app startup is deliberate: [WorkspaceStore.restore] is
  /// idempotent and a choice already made this session always wins, so the screen can be dropped
  /// into a test (or a future shell that forgets) and still work. The plan is computed only when
  /// nobody has one yet — reopening this screen must not re-fetch a whole tenant.
  Future<void> _bootstrap() async {
    final GitopsStore store = ref.read(gitopsProvider.notifier);
    await store.restoreWorkspace();
    if (!mounted) return;
    final PlanState plan = ref.read(gitopsProvider).plan;
    if (ref.read(workspaceProvider) == null || plan.hasPlan || plan.isRunning) {
      return;
    }
    await store.refreshPlan();
  }

  /// Point at a different folder and plan against it.
  ///
  /// `setWorkspace` drops the previous folder's plan and report before this runs, so there is
  /// never a window where rows computed for one tree sit under another tree's name.
  Future<void> _chooseWorkspace() async {
    final String? picked = await getDirectoryPath(
      confirmButtonText: 'Use Folder',
      initialDirectory: ref.read(workspaceProvider),
    );
    if (picked == null || !mounted) return;
    final GitopsStore store = ref.read(gitopsProvider.notifier);
    await store.setWorkspace(picked);
    if (!mounted) return;
    // Straight into a plan: `refreshPlan` stats for `gitops/` first, so a folder that is not a
    // workspace costs one filesystem call rather than a full network diff with nothing to
    // compare against.
    await store.refreshPlan();
  }

  /// Turn a plain folder into a GitOps workspace — or refresh one — with `abctl seed`.
  ///
  /// The tree check happens HERE, once, and its answer travels into the dialog and back out as a
  /// [SeedConsent]: the dialog asks the question the tree makes appropriate, and the store refuses
  /// the destructive answer unless it is the one the user actually gave. Nothing on this path can
  /// overwrite a checkout by defaulting a boolean.
  ///
  /// The plan is not recomputed here. `seedWorkspace` hands off to it itself, so the seed's
  /// transcript and the diff's belong to one run log rather than two.
  Future<void> _seedWorkspace() async {
    final String? workspace = ref.read(workspaceProvider);
    if (workspace == null) return;
    final bool hasTree = GitopsStore.hasGitopsTree(workspace);
    final SeedConsent? consent = await SeedWorkspaceDialog.confirm(
      context,
      workspace: workspace,
      hasTree: hasTree,
    );
    if (consent == null || !mounted) return;
    await ref.read(gitopsProvider.notifier).seedWorkspace(consent: consent);
  }

  /// Flip which side `diff` treats as the desired state, and recompute.
  ///
  /// The Swift original gated this behind a confirmation dialog because the same flag makes
  /// `sync --apply` remove things. It still does — but the flip itself writes nothing, and the
  /// consent it used to collect is now collected where the write is: [ApplyDialog] states the
  /// consequence in numbers and takes a typed confirmation, which is a better gate than a
  /// yes/no over a switch two steps earlier.
  ///
  /// What the flip DOES do is invalidate the plan on screen — the store drops it, because a plan
  /// sitting under a switch that now says something else is a lie whichever way it is read — so
  /// recomputing is not optional. That is also what stops the two verbs disagreeing: an apply
  /// whose mode does not match the plan's is refused by the store outright.
  Future<void> _toggleGitSourceOfTruth(bool enabled) async {
    final GitopsStore store = ref.read(gitopsProvider.notifier);
    store.setGitSourceOfTruth(enabled);
    if (ref.read(workspaceProvider) == null) return;
    await store.refreshPlan();
  }

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    // Three selects rather than one watch of the whole store: verifying profiles publishes a new
    // `GitopsState` on every transition, and a `ValidateDialog` re-running its check must not
    // rebuild a five hundred row plan table underneath it.
    final PlanState plan = ref.watch(gitopsProvider.select((s) => s.plan));
    final bool gitSourceOfTruth = ref.watch(
      gitopsProvider.select((s) => s.gitSourceOfTruth),
    );
    final AbctlRefresh refresh = ref.watch(
      gitopsProvider.select((s) => s.refresh),
    );
    // A fourth select, for the same reason as the other three: a seed publishes a new `GitopsState`
    // when it starts, when it finishes and when its summary is dismissed, and none of those may
    // re-derive a five hundred row plan table.
    final SeedState seed = ref.watch(gitopsProvider.select((s) => s.seed));
    // A fifth, and the one with the most traffic behind it: an apply publishes on every
    // transition of a run that lasts minutes. Only two things up here depend on it — whether the
    // toolbar is busy, and whether the plan has been superseded — and neither is worth re-sorting
    // the table for.
    final ApplyState apply = ref.watch(gitopsProvider.select((s) => s.apply));
    final String? workspace = ref.watch(workspaceProvider);
    // "A workspace verb is running", computed ONCE and handed to everything that has to obey it.
    // It used to be derived inside `_toolbar`, which is how the plan table's own Retry ended up
    // being the single control on this screen gated on the plan alone.
    final bool busy = plan.isRunning || seed.isRunning || apply.isRunning;

    return DecoratedBox(
      decoration: BoxDecoration(color: ab.canvas),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _toolbar(
            ab,
            plan,
            seed,
            workspace,
            gitSourceOfTruth,
            refresh,
            busy: busy,
          ),
          // The rows are still on screen because they are the record of what was just applied —
          // and they are no longer an answer to "what is pending", which is the only reason
          // anyone reads this table. Stated as a banner rather than by emptying the table,
          // because an operator who has just applied wants to see what they applied.
          if (plan.superseded)
            NoticeBanner(
              icon: abIcon('exclamationmark.circle'),
              tone: AbSeverity.drift,
              text: 'These rows were applied',
              detail:
                  'They describe the tenant as it was BEFORE the last apply. Refresh to see what '
                  'is pending now.',
            ),
          // Exit 3 is abctl saying "changes pending", which is a NORMAL verdict about the tenant
          // and not a failure of the command. It reaches the screen as a note, in the amber that
          // means drift, never in the red that means something broke.
          if (plan.note != null)
            NoticeBanner(
              icon: abIcon('exclamationmark.circle'),
              tone: AbSeverity.drift,
              text: 'abctl reported changes pending',
              detail: plan.note,
            ),
          // The seed's own result, kept out of the plan's error slot on purpose: a seed that
          // failed and a diff that failed are different sentences about different commands, and
          // one shared banner is how a stale message ends up under the wrong spinner.
          if (seed.error != null)
            NoticeBanner(
              icon: abIcon('exclamationmark.triangle'),
              tone: AbSeverity.danger,
              text: 'Couldn\'t initialize the workspace',
              detail: seed.error,
              trailing: _DismissSeedButton(),
            ),
          if (seed.summary != null)
            NoticeBanner(
              icon: abIcon('checkmark.seal'),
              tone: AbSeverity.ok,
              text: 'Workspace initialized',
              // abctl's own words, first line only — the rest of its narration is in the progress
              // pane and the run log, and a banner is one line high.
              detail: _firstLine(seed.summary!),
              trailing: _DismissSeedButton(),
            ),
          Expanded(child: _content(ab, plan, seed, workspace, busy: busy)),
          if (plan.isRunning || seed.isRunning)
            _ProgressStrip(
              gitSourceOfTruth: gitSourceOfTruth,
              // The seed wins the label during the hand-off: for the last stretch of a seed both
              // flags are on, and "Computing plan" over a run the user started as "Initialize"
              // reads as the app having wandered off to do something else.
              seeding: seed.isRunning,
            ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------------------------
  // toolbar
  // -----------------------------------------------------------------------------------------

  /// [busy] is "a workspace verb is running", passed in rather than derived here.
  ///
  /// The three are alternatives from the toolbar's point of view: a control that is safe to press
  /// during a seed but not during a plan does not exist here, and spelling every condition at
  /// each button is how one of them gets forgotten. The apply belongs in it for a harder reason
  /// than the others — abctl is writing to the tenant, and every control up here would make that
  /// write describe a different question. It is computed in `build` because the plan table's
  /// Retry needs the same answer, and deriving it twice is what let those two drift apart.
  Widget _toolbar(
    AbColors ab,
    PlanState plan,
    SeedState seed,
    String? workspace,
    bool gitSourceOfTruth,
    AbctlRefresh refresh, {
    required bool busy,
  }) {
    final bool hasWorkspace = workspace != null;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbSpace.md,
        vertical: AbSpace.sm,
      ),
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border(bottom: BorderSide(color: ab.line)),
      ),
      child: Row(
        children: <Widget>[
          Icon(abIcon('arrow.triangle.branch'), size: 16, color: ab.accent),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Diff / Drift',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: ab.text,
                  ),
                ),
                Tooltip(
                  // The full path, because the folder NAME is what fits on screen and two
                  // checkouts of the same repo have the same one.
                  message: workspace ?? 'No workspace chosen',
                  child: MonoText(
                    workspace == null ? 'no workspace' : folderLabel(workspace),
                    size: 11,
                    color: ab.faint,
                  ),
                ),
              ],
            ),
          ),
          // Wrap, not Row: seven controls do not fit a narrow window, and a toolbar that
          // silently clips its last item is the exact defect the Swift original shipped with
          // (at ~1090px). Wrapping to a second line costs a few pixels of height and loses
          // nothing.
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              children: <Widget>[
                _GitSourceOfTruthButton(
                  isOn: gitSourceOfTruth,
                  onChanged: hasWorkspace && !busy
                      ? (bool value) =>
                            unawaited(_toggleGitSourceOfTruth(value))
                      : null,
                ),
                _RefreshModeButton(
                  mode: refresh,
                  onChanged: busy
                      ? null
                      : (AbctlRefresh mode) =>
                            ref.read(gitopsProvider.notifier).setRefresh(mode),
                ),
                ToolbarButton(
                  icon: abIcon('checkmark.shield'),
                  label: 'Verify Configs',
                  weight: AbToolbarWeight.titled,
                  tooltip:
                      'Check the profiles in gitops/lib against Apple\'s schema, and that the '
                      'blueprints only reference configurations that exist. Reads local files '
                      'only — no credentials and no tenant call.',
                  // Disabled during a seed, and only during a seed: `validate` reads the files
                  // abctl is at that moment rewriting, so a report from mid-seed describes a tree
                  // that does not exist yet in either shape.
                  onPressed: hasWorkspace && !seed.isRunning
                      ? () => unawaited(ValidateDialog.show(context))
                      : null,
                ),
                // Seeding lives in the toolbar as well as in the empty state, because it is not
                // only a first-run action: `seed` also REFRESHES a workspace whose baseline has
                // drifted from the tenant. The empty state is where it is discovered; this is
                // where it is found again.
                ToolbarButton(
                  icon: abIcon('folder.badge.plus'),
                  label: 'Seed',
                  tooltip:
                      'Download the live configurations and blueprints into this folder\'s '
                      'gitops/ tree. Reads Apple Business and writes local files — the tenant is '
                      'not changed. Asks first, and asks harder if a tree is already there.',
                  onPressed: hasWorkspace && !busy
                      ? () => unawaited(_seedWorkspace())
                      : null,
                ),
                // The write. Titled, because it is the one control here whose consequence must
                // not be misread — and it opens a dialog rather than doing anything, so this
                // button is never the last thing between a click and Apple Business.
                //
                // Enabled only with rows to apply: `sync --apply` against an empty plan is a
                // tenant round-trip that changes nothing, and a live Apply over "In sync" invites
                // the click that finds that out.
                ToolbarButton(
                  icon: abIcon('checkmark.circle'),
                  label: 'Apply',
                  weight: AbToolbarWeight.titled,
                  tooltip:
                      'Reconcile Apple Business with this plan — the only command in abgui that '
                      'changes the tenant. Opens a confirmation showing exactly what will run, '
                      'what it can remove, and what is recoverable afterwards.',
                  onPressed:
                      hasWorkspace && !busy && _rowsFor(plan.plan).isNotEmpty
                      ? () => unawaited(ApplyDialog.show(context))
                      : null,
                ),
                ToolbarButton(
                  icon: abIcon('arrow.clockwise'),
                  label: 'Refresh',
                  tooltip:
                      'Recompute the plan: re-read gitops/ and re-fetch the live tenant.',
                  onPressed: hasWorkspace && !busy
                      ? () => unawaited(
                          ref.read(gitopsProvider.notifier).refreshPlan(),
                        )
                      : null,
                ),
                ToolbarButton(
                  icon: abIcon('folder'),
                  label: 'Workspace',
                  tooltip:
                      'Choose the folder that contains your gitops/ tree. Every command on this '
                      'screen runs there, because abctl resolves that tree against the directory '
                      'it runs in.',
                  onPressed: () => unawaited(_chooseWorkspace()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------------------------
  // content
  // -----------------------------------------------------------------------------------------

  Widget _content(
    AbColors ab,
    PlanState plan,
    SeedState seed,
    String? workspace, {
    required bool busy,
  }) {
    if (workspace == null) {
      return EmptyState(
        icon: abIcon('folder.badge.questionmark'),
        title: 'No GitOps workspace',
        message:
            'Choose the folder that contains your gitops/ tree. abctl resolves that tree '
            'against the directory it runs in, so a diff without one would plan against '
            'wherever the app happened to be launched from.',
        action: OutlinedButton(
          onPressed: () => unawaited(_chooseWorkspace()),
          child: const Text('Choose Workspace…'),
        ),
      );
    }

    if (plan.needsGitopsTree) {
      return EmptyState(
        icon: abIcon('folder.badge.plus'),
        title: 'No gitops/ tree in "${folderLabel(workspace)}"',
        message:
            'There is nothing to diff against yet. Initializing downloads the live '
            'configurations and blueprints into gitops/, plus a baseline for the 3-way diff — it '
            'reads Apple Business and writes files here, and changes nothing about the tenant. '
            'Pick a different folder if this is not the checkout you meant.',
        // ONE control, which is the rule `EmptyState` states for itself — an empty pane offering
        // four buttons is a menu rather than an explanation. Initializing is the action the
        // situation calls for; "choose another folder" is reachable from the toolbar, one glance
        // away, and is what someone who picked the wrong directory will look for there anyway.
        action: FilledButton(
          onPressed: seed.isRunning ? null : () => unawaited(_seedWorkspace()),
          child: const Text('Initialize from Tenant…'),
        ),
      );
    }

    final List<PlanRow> rows = _rowsFor(plan.plan);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (rows.isNotEmpty) _summary(ab, rows, plan, workspace),
        Expanded(
          child: AbTable<PlanRow>(
            rows: rows,
            columns: _planColumns,
            rowId: (PlanRow row) => row.id,
            density: ref.watch(settingsProvider.select((s) => s.density)),
            // Selection, not activation: there is no detail sheet for a plan row and nothing to
            // apply, so clicking a row means "show me this one's full detail" in the strip below.
            selectionMode: AbSelectionMode.single,
            onSelectionChanged: (List<PlanRow> selected) => setState(
              () => _focused = selected.isEmpty ? null : selected.first,
            ),
            severity: (PlanRow row) => row.consequence.severity,
            isLoading: plan.isRunning,
            error: plan.error,
            initialSortColumn: 'Action',
            semanticsLabel: 'Pending changes',
            reportsStatus: true,
            emptyIcon: plan.hasPlan
                ? abIcon('checkmark.seal')
                : abIcon('arrow.triangle.branch'),
            emptyTitle: plan.hasPlan ? 'In sync' : 'No plan yet',
            emptyMessage: plan.hasPlan
                ? _checkedSuffix(
                    'Git and the tenant agree: no drift.',
                    plan.checkedAt,
                  )
                : 'Refresh to compute drift between gitops/ and the live tenant.',
            errorAction: ToolbarButton(
              icon: abIcon('arrow.clockwise'),
              label: 'Retry',
              weight: AbToolbarWeight.titled,
              tooltip: 'Run `abctl diff --json` again.',
              // `busy`, not `plan.isRunning`: this is the same Refresh as the toolbar's, so it
              // takes the toolbar's rule. It was the one control on this screen still gated on
              // the plan alone, which made it the only way to ask for a diff during a seed or an
              // apply — and the store now refuses that outright, so a live button here would only
              // be a button that produces a refusal.
              onPressed: busy
                  ? null
                  : () => unawaited(
                      ref.read(gitopsProvider.notifier).refreshPlan(),
                    ),
            ),
          ),
        ),
        if (_focused != null) _RowDetailStrip(row: _focused!),
      ],
    );
  }

  /// The line that answers "how bad is this?" before the table answers "what is it?".
  ///
  /// Counting by consequence rather than by row is the whole point: "5 changes" is true of a plan
  /// that creates five configurations and of one that deletes four of them, and those are not the
  /// same morning. Each count carries its own word as well as its own colour.
  Widget _summary(
    AbColors ab,
    List<PlanRow> rows,
    PlanState plan,
    String workspace,
  ) {
    final Map<PlanConsequence, int> counts = PlanRow.countByConsequence(rows);
    final int blocked = rows.where((PlanRow row) => row.blocked).length;
    final int local = rows.where((PlanRow row) => row.writesTree).length;
    final bool destructive = (counts[PlanConsequence.destructive] ?? 0) > 0;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbSpace.md,
        vertical: AbSpace.sm,
      ),
      decoration: BoxDecoration(
        color: ab.surface,
        border: Border(bottom: BorderSide(color: ab.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2, right: AbSpace.sm),
            child: Icon(
              abIcon(
                destructive
                    ? 'exclamationmark.triangle'
                    : 'exclamationmark.circle',
              ),
              size: 15,
              color: destructive ? ab.danger : ab.drift,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AbSpace.sm,
                  runSpacing: AbSpace.xs,
                  children: <Widget>[
                    Text(
                      rows.length == 1
                          ? '1 pending change'
                          : '${rows.length} pending changes',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ab.text,
                      ),
                    ),
                    for (final PlanConsequence consequence
                        in PlanConsequence.values)
                      if ((counts[consequence] ?? 0) > 0)
                        Tooltip(
                          message: consequence.explanation,
                          child: AbBadge(
                            label:
                                '${counts[consequence]} ${consequence.countWord}',
                            severity: consequence.severity,
                          ),
                        ),
                    if (blocked > 0)
                      Tooltip(
                        // Neutral, not red: a blocked row is not a worse change, it is a change
                        // abctl cannot perform yet. The word carries it.
                        //
                        // Counted in the totals above as well, deliberately: the counts have to
                        // add up to the number of rows in the table, and a row that exists but is
                        // missing from every count is a row the reader will hunt for.
                        message:
                            'Included in the counts above, but abctl cannot perform them yet — an '
                            'attach whose member does not exist in Apple Business has no id to '
                            'attach. They are reported so that the plan is complete.',
                        child: AbBadge(label: '$blocked blocked'),
                      ),
                  ],
                ),
                if (local > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      local == 1
                          ? '1 of them would write gitops/ rather than Apple Business.'
                          : '$local of them would write gitops/ rather than Apple Business.',
                      style: TextStyle(fontSize: 11, color: ab.faint),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AbSpace.md),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              MonoText(folderLabel(workspace), size: 11, color: ab.dim),
              if (plan.checkedAt != null)
                MonoText(
                  // Absolute rather than "3m ago": this text is rebuilt when the plan changes,
                  // not on a timer, and a relative reading that stopped ticking half an hour ago
                  // is a confident lie about how fresh the rows are.
                  'checked ${AbRelativeTime.absolute(plan.checkedAt!)}',
                  size: 10,
                  color: ab.faint,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `"<sentence>\nChecked <when>"`, or just the sentence when nothing has been checked yet.
///
/// The stamp is what makes Refresh on an already-in-sync tenant visibly different from a dead
/// button: the verdict is identical, so the TIME is the only thing that can change.
String _checkedSuffix(String sentence, DateTime? checkedAt) => checkedAt == null
    ? sentence
    : '$sentence\nChecked ${AbRelativeTime.absolute(checkedAt)}';

/// abctl's first sentence, for a banner that is one line high.
///
/// A seed prints a paragraph — every configuration it wrote, then a count. The whole of it is in
/// the progress pane and in the run log, both of which are still on screen; repeating it inside a
/// strip that ellipsises at two lines would only make the strip unreadable.
String _firstLine(String text) {
  final String trimmed = text.trim();
  final int newline = trimmed.indexOf('\n');
  return newline < 0 ? trimmed : trimmed.substring(0, newline).trimRight();
}

/// Clears the seed's last word from the screen.
///
/// A seed's result is a fact about a moment. Left standing, "Workspace initialized" sits above a
/// plan computed half an hour later and starts reading as a claim about that.
class _DismissSeedButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) => ToolbarButton(
    icon: abIcon('xmark'),
    label: 'Dismiss',
    tooltip: 'Hide this message. Nothing about the workspace changes.',
    onPressed: () => ref.read(gitopsProvider.notifier).dismissSeedSummary(),
  );
}

// ---------------------------------------------------------------------------------------------
// the plan, as rows
// ---------------------------------------------------------------------------------------------

/// What applying a plan row would DO to the world.
///
/// abctl's `action` strings say what VERB runs (`create-abm`, `detach-app`, `pull-git`); this
/// says what that verb costs you if it is wrong. It is the only thing on this screen encoded in
/// colour, and it is encoded in words at the same time — the pill's label, the summary's counts
/// and the row's spoken semantics all carry it.
enum PlanConsequence {
  /// Creates something that did not exist. Nothing is overwritten and nothing is lost.
  additive(AbSeverity.ok, 'add'),

  /// Overwrites something that exists, on one side or the other.
  mutating(AbSeverity.drift, 'change'),

  /// Removes something: a configuration deleted, a member detached from a blueprint, a local
  /// file dropped because Apple no longer has it.
  destructive(AbSeverity.danger, 'remove');

  const PlanConsequence(this.severity, this.countWord);

  /// The palette's own three-level scale — the stripe, the pill and the summary badge all read
  /// this rather than each choosing a colour. See `AbColors`' doc comment for why that matters.
  final AbSeverity severity;

  /// The word in the summary: "3 add · 2 change · 1 remove".
  final String countWord;

  String get explanation => switch (this) {
    PlanConsequence.additive =>
      'Additive — creates something that does not exist yet. Nothing is overwritten or removed.',
    PlanConsequence.mutating =>
      'Mutating — overwrites something that already exists, in Apple Business or in gitops/.',
    PlanConsequence.destructive =>
      'Destructive — deletes a configuration, drops a local file, or detaches a member from a '
          'blueprint.',
  };

  /// Classify one of abctl's action strings.
  ///
  /// Two rules, both learned from the models this reads:
  ///
  ///  * The member actions are matched by PREFIX, never by equality. abctl manages six member
  ///    collections (`attach-config`, `detach-app`, `adopt-user`, …) and spelling only the
  ///    `-config` pair is what silently misclassified every app/package/device/user/group row in
  ///    the Swift app (see `BlueprintChange.action`).
  ///  * An action nobody here recognizes is [mutating], never [additive]. abctl's vocabulary
  ///    grows; a plan screen that files an unknown verb under "nothing is lost" is exactly the
  ///    kind of quiet downgrade `TreeIssue` refuses to make for an unclassifiable level.
  static PlanConsequence of(String action) {
    switch (action) {
      case 'create-abm':
      case 'pull-new-git':
      case 'blueprint-new':
      case 'blueprint-adopt':
        return PlanConsequence.additive;
      case 'update-abm':
      case 'pull-git':
      // Both sides changed and abctl will not guess. Not destructive — applying it does not
      // delete anything — but never additive either: one side's edit is about to lose.
      case 'conflict':
        return PlanConsequence.mutating;
      case 'delete-abm':
      case 'delete-git':
        return PlanConsequence.destructive;
    }
    if (action.startsWith('detach-')) return PlanConsequence.destructive;
    // An adopt WRITES a member into a blueprint manifest that was missing it; an attach adds a
    // member to a blueprint in Apple Business. Both add, neither removes.
    if (action.startsWith('attach-') || action.startsWith('adopt-')) {
      return PlanConsequence.additive;
    }
    return PlanConsequence.mutating;
  }
}

/// One row of the plan table — a [ConfigChange] and a [BlueprintChange] flattened into the one
/// shape the table sorts, filters and speaks.
///
/// Flattened rather than rendered as two tables because a reviewer's question ("is anything
/// being deleted?") spans both lists, and two tables cannot be sorted against each other. What is
/// lost — which of abctl's two arrays a row came from — is not lost at all: the action names it.
@immutable
class PlanRow {
  const PlanRow({
    required this.id,
    required this.action,
    required this.target,
    required this.member,
    required this.detail,
    required this.blocked,
    required this.writesTree,
  });

  /// Unique within one plan. The index prefix is load-bearing: two rows can legitimately share
  /// `action:name` (the same member proposed twice against different blueprints resolves to the
  /// same key), and `AbTable` holds selection by id.
  final String id;

  final String action;

  /// The configuration, or the blueprint a membership row is about.
  final String target;

  /// The member a blueprint row addresses. Empty for configuration rows.
  final String member;

  /// abctl's own sentence about this row.
  final String detail;

  /// abctl reported it but cannot perform it — `BlueprintChange.isActionable` is false, which
  /// today means an attach whose member has no resolved id in Apple Business.
  final bool blocked;

  /// Applying it would write the local `gitops/` tree instead of the tenant: the pull family and
  /// every blueprint adopt.
  final bool writesTree;

  PlanConsequence get consequence => PlanConsequence.of(action);

  /// Flatten a plan. A null plan (nobody has computed one yet) is an empty table, not a crash —
  /// the table's own empty state says which of those it is.
  static List<PlanRow> of(Plan? plan) {
    if (plan == null) return const <PlanRow>[];
    return <PlanRow>[
      for (int i = 0; i < plan.configs.length; i++)
        PlanRow(
          id: 'c$i:${plan.configs[i].id}',
          action: plan.configs[i].action,
          target: plan.configs[i].name,
          member: '',
          detail: plan.configs[i].detail,
          blocked: false,
          writesTree: plan.configs[i].isLocal,
        ),
      for (int i = 0; i < plan.blueprints.length; i++)
        PlanRow(
          id: 'b$i:${plan.blueprints[i].id}',
          action: plan.blueprints[i].action,
          target: plan.blueprints[i].blueprint,
          member: plan.blueprints[i].config ?? '',
          detail: plan.blueprints[i].detail,
          blocked: !plan.blueprints[i].isActionable,
          writesTree: plan.blueprints[i].isAdopt,
        ),
    ];
  }

  static Map<PlanConsequence, int> countByConsequence(List<PlanRow> rows) {
    final Map<PlanConsequence, int> counts = <PlanConsequence, int>{};
    for (final PlanRow row in rows) {
      counts[row.consequence] = (counts[row.consequence] ?? 0) + 1;
    }
    return counts;
  }
}

/// The table's shape. Built once at the top level because none of it closes over widget state —
/// `AbTable` compares columns by header and type, so a list rebuilt per frame would only cost
/// re-derivations it is designed to avoid.
final List<AbColumn<PlanRow>> _planColumns = <AbColumn<PlanRow>>[
  AbColumn<PlanRow>(
    header: 'Action',
    value: (PlanRow row) => row.action,
    type: AbColumnType.badge,
    width: 168,
    severity: (PlanRow row) => row.consequence.severity,
    // The grouping. Ascending means MOST consequential first, which is the opposite of the
    // enum's declaration order and deliberate: a plan whose three deletes sit below two hundred
    // attaches has hidden the only rows that can lose data. Equal consequences fall back to the
    // action name, which puts every `detach-app` together, and `AbTable` breaks the remaining
    // ties on source index so abctl's own order survives inside a group.
    compare: (PlanRow a, PlanRow b) {
      final int tier = b.consequence.index.compareTo(a.consequence.index);
      return tier != 0 ? tier : AbNaturalOrder.compare(a.action, b.action);
    },
  ),
  AbColumn<PlanRow>(
    header: 'Target',
    value: (PlanRow row) => row.target,
    flex: 2,
    minWidth: 150,
  ),
  AbColumn<PlanRow>(
    header: 'Member',
    // An em dash, not an empty cell: a configuration row addresses no member, and blank reads as
    // "we could not find one".
    value: (PlanRow row) => row.member.isEmpty ? '—' : row.member,
    flex: 2,
    minWidth: 130,
  ),
  AbColumn<PlanRow>(
    header: 'Writes',
    // The question every plan row raises second: does this touch the tenant, or my working tree?
    value: (PlanRow row) => row.writesTree ? 'gitops/' : 'tenant',
    type: AbColumnType.mono,
    width: 92,
  ),
  AbColumn<PlanRow>(
    header: 'State',
    value: (PlanRow row) => row.blocked ? 'blocked' : 'pending',
    type: AbColumnType.badge,
    width: 104,
    severity: (PlanRow row) =>
        row.blocked ? AbSeverity.danger : AbSeverity.neutral,
  ),
  AbColumn<PlanRow>(
    header: 'Detail',
    value: (PlanRow row) => row.detail,
    flex: 4,
    minWidth: 260,
  ),
];

// ---------------------------------------------------------------------------------------------
// pieces
// ---------------------------------------------------------------------------------------------

/// The full text of the selected row, under the table.
///
/// It exists because an `AbTable` row is one fixed-height line — that is what makes five thousand
/// rows cheap — and abctl's `detail` is a sentence. Ellipsising the sentence is fine as long as
/// there is somewhere it can be read in full, and this is that place: wrapped, selectable, and
/// naming the row it belongs to so it cannot be read against the wrong one.
class _RowDetailStrip extends StatelessWidget {
  const _RowDetailStrip({required this.row});

  final PlanRow row;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final String subject = row.member.isEmpty
        ? row.target
        : '${row.target} → ${row.member}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AbSpace.md,
        vertical: AbSpace.sm,
      ),
      decoration: BoxDecoration(
        color: ab.surface,
        border: Border(top: BorderSide(color: ab.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AbBadge(label: row.action, severity: row.consequence.severity),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: SelectableText.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: subject,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                  if (row.detail.isNotEmpty)
                    TextSpan(
                      text: '  ·  ${row.detail}',
                      style: TextStyle(fontSize: 12, color: ab.dim),
                    ),
                  if (row.blocked)
                    TextSpan(
                      text:
                          '\nBlocked: abctl cannot perform this until the member exists in '
                          'Apple Business.',
                      style: TextStyle(fontSize: 11, color: ab.danger),
                    ),
                ],
              ),
              maxLines: 4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Which side `diff` treats as the desired state.
///
/// A plain button showing ON/OFF rather than a `Switch`: the two states are not "enabled/
/// disabled", they are two different questions being asked of the same tenant, and the tooltip
/// is where that difference is stated in full.
class _GitSourceOfTruthButton extends StatelessWidget {
  const _GitSourceOfTruthButton({required this.isOn, required this.onChanged});

  final bool isOn;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ToolbarButton(
      // The padlock is "git decides"; the two-way arrow is "the two sides merge". The glyph pair
      // is the one in `sf_icons.dart`, chosen there for exactly this control.
      icon: abIcon(isOn ? 'lock' : 'arrow.left.arrow.right'),
      label: isOn ? 'Git decides' : 'Two-way',
      weight: AbToolbarWeight.titled,
      selected: isOn,
      tooltip: isOn
          ? 'Git is the source of truth: anything live in Apple Business but absent from gitops/ '
                'is planned for removal — and applying this plan performs those removals, because '
                'a desired state applied without them is only half applied. Switching this off '
                'makes the plan additive again. The switch itself writes nothing; Apply is where '
                'that is decided.'
          : 'Two-way: the plan reconciles both sides and never proposes removing something just '
                'because git does not have it. Switching it on makes git authoritative — and the '
                'FIRST plan after the switch is the slow one, because every Apple-only '
                'configuration then has to be fetched in full.',
      onPressed: onChanged == null ? null : () => onChanged!(!isOn),
    );
  }
}

/// How much live state the NEXT plan re-reads.
///
/// A menu rather than a cycling button, because the three modes are a cost/accuracy trade and
/// "click through the other two to get back" is a poor way to make one. The child mirrors
/// `ToolbarButton`'s metrics by hand: `PopupMenuButton` has to own the tap, so the real control
/// cannot be nested inside it.
class _RefreshModeButton extends StatelessWidget {
  const _RefreshModeButton({required this.mode, required this.onChanged});

  final AbctlRefresh mode;
  final ValueChanged<AbctlRefresh>? onChanged;

  static String _describe(AbctlRefresh mode) => switch (mode) {
    AbctlRefresh.smart => 'Re-read what the plan needs. abctl\'s default.',
    AbctlRefresh.full =>
      'Re-read everything, including every profile payload. Slow on a large tenant.',
    AbctlRefresh.metadataOnly =>
      'Names and ids only — the cheapest plan abctl can build.',
  };

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Color ink = onChanged == null ? ab.faint : ab.dim;
    return Tooltip(
      message:
          'How much live state the next plan re-reads. It changes what a plan COSTS, not what it '
          'means, so the plan on screen stays as it is.\n\n${_describe(mode)}',
      child: PopupMenuButton<AbctlRefresh>(
        enabled: onChanged != null,
        position: PopupMenuPosition.under,
        // The menu is the tooltip's own content restated per item; a second tooltip on the
        // trigger would fight the one above it.
        tooltip: '',
        onSelected: onChanged,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<AbctlRefresh>>[
          for (final AbctlRefresh option in AbctlRefresh.values)
            PopupMenuItem<AbctlRefresh>(
              value: option,
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 20,
                    child: option == mode
                        ? Icon(abIcon('checkmark'), size: 13, color: ab.accent)
                        : null,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        MonoText(option.wire, size: 12, color: ab.text),
                        Text(
                          _describe(option),
                          style: TextStyle(fontSize: 11, color: ab.faint),
                          maxLines: 2,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AbSpace.sm,
            vertical: 5,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Re-read',
                style: TextStyle(
                  fontSize: 12,
                  color: ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 5),
              MonoText(mode.wire, size: 11.5, color: ink),
              Icon(abIcon('chevron.up.chevron.down'), size: 13, color: ink),
            ],
          ),
        ),
      ),
    );
  }
}

/// abctl's live narration while a plan runs, plus the Cancel that ends it.
///
/// **It listens to the sink directly, and that is the whole design.** `ProgressSink` is a plain
/// `ValueNotifier` outside Riverpod because a plan against a real tenant arrives as hundreds of
/// stderr lines; publishing each through a provider would invalidate every dependent per line on
/// the thread that also has to draw — the starvation bug that blanked the Swift window, ported
/// into a new language. Exactly one `ValueListenableBuilder` listens, so a burst repaints this
/// strip and nothing above it.
class _ProgressStrip extends ConsumerWidget {
  const _ProgressStrip({required this.gitSourceOfTruth, required this.seeding});

  final bool gitSourceOfTruth;

  /// Whether the run being narrated is a seed rather than a plan. It changes the label and — the
  /// part that matters — what Cancel promises: a cancelled plan has written nothing, a cancelled
  /// seed leaves a half-downloaded tree on disk.
  final bool seeding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final sink = ref.watch(progressSinkProvider);
    return Container(
      height: 168,
      decoration: BoxDecoration(
        color: ab.surface,
        border: Border(top: BorderSide(color: ab.line)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AbSpace.md,
        AbSpace.sm,
        AbSpace.md,
        AbSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: ab.accent,
                ),
              ),
              const SizedBox(width: AbSpace.sm),
              Text(
                seeding
                    ? 'Initializing workspace from the tenant'
                    : 'Computing plan',
                style: AbType.label(context),
              ),
              const Spacer(),
              CopyButton(
                text: () =>
                    ref.read(progressSinkProvider).lines.value.join('\n'),
                tooltip:
                    'Copy everything abctl has printed so far. The complete transcript is also '
                    'written to this run\'s log file.',
                weight: AbToolbarWeight.compact,
              ),
              ToolbarButton(
                icon: abIcon('stop.circle'),
                label: 'Cancel',
                weight: AbToolbarWeight.titled,
                // The promise is different for the two runs, and getting it wrong in the
                // reassuring direction would be the worst of the two: "nothing has been written"
                // over a half-downloaded tree is a false statement made at the exact moment
                // someone is deciding whether it is safe to stop.
                tooltip: seeding
                    ? 'Stop the running abctl. The tenant is untouched — seeding only reads it — '
                          'but the gitops/ tree will be half written. Seed again to finish it.'
                    : 'Stop the running abctl. Nothing has been written — `diff` only reads.',
                onPressed: () => ref.read(gitopsProvider.notifier).cancelWork(),
              ),
            ],
          ),
          // Silence during the slow case reads as a hung window, and this is the slow case:
          // turning git source of truth ON makes the FIRST plan after the flip fetch every
          // Apple-only configuration in full, because that mode may propose removing them and
          // abctl archives before it does (internal/cli/phase1.go, fetchLiveConfigsSmart).
          if (gitSourceOfTruth && !seeding)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Git source of truth is on, so Apple-only configurations are being fetched in '
                'full — the first plan after that switch is the slow one.',
                style: TextStyle(fontSize: 11, color: ab.faint),
              ),
            ),
          if (seeding)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Every configuration and blueprint is being fetched in full and written into '
                'gitops/. On a large tenant this takes minutes; the plan follows automatically.',
                style: TextStyle(fontSize: 11, color: ab.faint),
              ),
            ),
          const SizedBox(height: AbSpace.sm),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: ab.sunken,
                border: Border.all(color: ab.lineSoft),
                borderRadius: BorderRadius.circular(AbSpace.radius),
              ),
              padding: const EdgeInsets.all(AbSpace.sm),
              child: ValueListenableBuilder<List<String>>(
                valueListenable: sink.lines,
                builder: (BuildContext context, List<String> lines, Widget? child) {
                  if (lines.isEmpty) {
                    return Text(
                      'Waiting for abctl…',
                      style: AbType.mono(context, size: 11, color: ab.faint),
                    );
                  }
                  // One selectable block, not a stack of Texts: this is the pane a user
                  // watches during a slow diff, and a transcript that cannot be selected
                  // across lines cannot be pasted into a bug report. `reverse` keeps the
                  // newest line in view without a scroll controller to drive.
                  return SingleChildScrollView(
                    reverse: true,
                    // See `command_log_screen.dart`: a screen in the shell's IndexedStack must
                    // not claim the window's primary scroll controller — the Diff transcript and
                    // the Logs transcript are both alive at once as soon as the user has opened
                    // both screens.
                    primary: false,
                    child: SelectableText(
                      lines.join('\n'),
                      style: AbType.mono(context, size: 11, color: ab.dim),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
