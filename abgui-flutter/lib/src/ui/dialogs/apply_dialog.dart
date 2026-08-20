// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/models/apply_result.dart';
import 'package:abgui/src/models/plan.dart';
import 'package:abgui/src/models/sync_failure.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/screens/diff_screen.dart'
    show PlanConsequence, PlanRow;
import 'package:abgui/src/ui/text_labels.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart' show AbRelativeTime;
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/copy_button.dart';
import 'package:abgui/src/ui/widgets/elapsed_ticker.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// The gated converge: `abctl sync --apply` against a live Apple Business tenant.
///
/// **This is the only screen in the app that changes another company's configuration, and every
/// choice below is arranged around one question: what does the operator have to know BEFORE they
/// press the button, and what must they never be able to press by accident?**
///
///  * **Counts by CONSEQUENCE, not by row.** "5 changes" is true of a plan that creates five
///    configurations and of one that deletes four of them. The classification is
///    [PlanConsequence] — imported from the Diff screen rather than re-derived here, because a
///    second copy of "which verbs remove things" is exactly how the Swift app came to file every
///    `detach-app` row under "nothing is lost" while the summary said otherwise.
///  * **The command shown is the command that runs.** It is `previewArgv` of
///    `AbctlArgs.syncApply(options)` — the same function the client hands the process (invariant
///    2 in `write_safety_test.dart`). A confirmation that displayed a lookalike would collect an
///    approval for something nobody saw.
///  * **Removals get their own block, with numbers.** How many live configurations, how many
///    memberships, and what is recoverable afterwards — stated precisely, because "it's fine,
///    there's an archive" is only true of the half of it that abctl archives.
///  * **The gate scales with the consequence.** An additive apply is one button. Anything that
///    can remove something requires typing the tenant's name, compared trimmed and
///    case-sensitively: a plain "Are you sure?" is a keystroke, and this is not a keystroke
///    decision.
///  * **Nothing here can spell a removal flag.** The command is built from exactly one
///    [ApplyOptions] value, whose constructors are named for their consequences; there is no
///    boolean on this screen wired to anything abctl reads.
///  * **The verdict is never the exit code.** [ApplyState.verdict] reads the receipt and the exit
///    status together, and this dialog renders that — a run in which every item says `done` and
///    abctl still exited non-zero is a run whose writes Apple did not keep.
class ApplyDialog extends ConsumerStatefulWidget {
  const ApplyDialog({super.key});

  /// Present the dialog. The run itself lives in [GitopsStore], so nothing is handed back — and
  /// so a dialog closed mid-apply does not orphan a tenant write.
  ///
  /// Not barrier-dismissible: a stray click outside a sheet that is writing to Apple Business
  /// must not be the thing that hides the outcome the operator has to read.
  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => const ApplyDialog(),
    );
  }

  @override
  ConsumerState<ApplyDialog> createState() => _ApplyDialogState();
}

class _ApplyDialogState extends ConsumerState<ApplyDialog> {
  /// Whether this run may remove things — the operator's answer, in the two-way mode where there
  /// is a question to answer.
  ///
  /// Under git-as-truth there is no question: git being the complete desired state IS the
  /// instruction to remove what git does not declare, so [_options] ignores this field there.
  ///
  /// **Read the default honestly.** [_RemovalPolicy.keep] is the safe answer to the question this
  /// field asks, but it is NOT the app's default behaviour, because `GitopsState.gitSourceOfTruth`
  /// defaults to true and this field is then unread — a fresh launch that picks a workspace and
  /// presses Apply runs with `--prune`. That is faithful to abctl (`internal/cli/phase1.go` forces
  /// prune for `--apply --git-source-of-truth`) and to the Swift original, and it is deliberate
  /// rather than inherited: see `write_safety_test.dart`, which pins the default's argv so it
  /// cannot change in either direction without someone deciding to. What makes it safe is not the
  /// default — it is that git-as-truth is always gated ([_isGated] reads `options.prune`) and that
  /// [_RemovalBlock] says so in words above the button.
  _RemovalPolicy _policy = _RemovalPolicy.keep;

  /// How much of what this run writes abctl reads back afterwards. Targeted is abctl's default
  /// and abgui's; see [_VerifyButton] for why "none" is not the same as a clean verdict.
  AbctlVerify _verify = AbctlVerify.targeted;

  /// The circuit breaker, as typed. Parsed once, in [_options], so the line the operator reads
  /// and the process that starts cannot disagree about what it means.
  final TextEditingController _limit = TextEditingController();

  /// The typed confirmation. Held in a controller AND mirrored into [_typed] by the listener,
  /// because the Apply button's enablement depends on it and a controller does not rebuild this
  /// widget on its own.
  final TextEditingController _confirm = TextEditingController();
  String _typed = '';

  /// WHAT the text in [_confirm] was typed against — [_gateSubject] as of the last keystroke.
  ///
  /// **A confirmation is approval of a command, not of a phrase, and this is what makes the
  /// difference checkable.** Without it the gate opened once and stayed open: a plan that
  /// PROPOSES a removal is gated even when the command would skip it ([_isGated] is the union, on
  /// purpose), so the operator could read "This run skips the 1 removal in the plan", type the
  /// tenant's name against a provably non-destructive command, then brush the adjacent "Removals
  /// off" toggle — one `setState`, no re-typing — and press Apply. `--prune` reached the tenant
  /// carrying a confirmation collected for a command without it. The file's own justification for
  /// gating a skipping run is that the toggle must be "a decision rather than a click"; this is
  /// the half that makes that true. The same hole existed in reverse: a plan whose removals
  /// disappeared un-gated the field, hiding it with the phrase still inside, and a plan that
  /// re-proposed one brought it back already satisfied.
  ///
  /// Null until something is typed. Compared to the CURRENT subject in [_footer], so any change
  /// to what Apply would do — the prune flag, the removals on screen, the tenant being named —
  /// closes the gate.
  String? _confirmedFor;

  @override
  void initState() {
    super.initState();
    // Both fields rewrite something the operator is reading — the command preview for the limit,
    // the Apply button for the confirmation — so both have to repaint per keystroke. They are
    // the only per-keystroke rebuilds on this screen, and they cost one dialog, not the window.
    _limit.addListener(_onTextChanged);
    _confirm.addListener(_onConfirmChanged);
  }

  void _onTextChanged() => setState(() {});

  void _onConfirmChanged() => setState(() {
    _typed = _confirm.text;
    _confirmedFor = _currentGateSubject();
  });

  /// The gate's subject as the store and this widget's controls describe it RIGHT NOW.
  ///
  /// Recomputed from providers with `ref.read` rather than captured from the last `build`, so the
  /// value stamped onto a keystroke and the value compared against it in [_footer] come from the
  /// same expression — a subject derived two ways is a gate that disagrees with itself.
  String _currentGateSubject() {
    final GitopsState gitops = ref.read(gitopsProvider);
    final ApplyOptions options = _options(
      gitSourceOfTruth: gitops.gitSourceOfTruth,
      refresh: gitops.refresh,
    );
    return _gateSubject(
      options: options,
      removals: _Removals.of(gitops.plan.plan),
      phrase: _phrase(
        ref.read(activeContextProvider),
        ref.read(workspaceProvider),
      ),
    );
  }

  /// The three facts a confirmation is given FOR, as one comparable string.
  ///
  /// Whether the command removes things, how much the plan on screen proposes removing, and which
  /// tenant is being named. Deliberately not the whole [ApplyOptions]: changing `--verify` or the
  /// write limit does not change what the operator was asked to approve, and a gate that
  /// re-closed on every keystroke in the limit field would be a gate people learn to defeat by
  /// typing the name last.
  static String _gateSubject({
    required ApplyOptions options,
    required _Removals removals,
    required String phrase,
  }) => '${options.prune}|${removals.total}|$phrase';

  @override
  void dispose() {
    _limit.dispose();
    _confirm.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------------------------------
  // the command
  // -----------------------------------------------------------------------------------------

  /// Everything this run will do, as ONE value.
  ///
  /// **The only place in this file that decides what the command permits, and it does so by
  /// choosing a constructor rather than by setting a flag.** There is no removal-shaped argument
  /// to pass: under git-as-truth removals are implied by the mode (a desired state applied
  /// without them is only half applied, and abctl forces it anyway —
  /// `internal/cli/phase1.go`), and in the two-way mode they come from a named constructor whose
  /// name is the confirmation. A control that could turn one on without going through here would
  /// be a control the preview above it does not describe.
  ApplyOptions _options({
    required bool gitSourceOfTruth,
    required AbctlRefresh refresh,
  }) {
    // Non-numeric text means "unlimited", exactly as the Swift original read it, and the builder
    // then emits no flag at all — a preview showing a breaker the run does not arm would be a
    // promise nothing keeps.
    final int? limit = int.tryParse(_limit.text.trim());
    final AbctlRefresh mode = _applyRefresh(refresh);
    if (gitSourceOfTruth) {
      return ApplyOptions.gitAuthoritative(
        refresh: mode,
        verify: _verify,
        limitWrites: limit,
      );
    }
    return _policy == _RemovalPolicy.allow
        ? ApplyOptions.additiveAllowingDeletes(
            refresh: mode,
            verify: _verify,
            limitWrites: limit,
          )
        : ApplyOptions.additive(
            refresh: mode,
            verify: _verify,
            limitWrites: limit,
          );
  }

  /// The refresh mode an APPLY can use, given the one the plan was computed with.
  ///
  /// abctl refuses `--apply` with `--refresh=metadata-only` outright: that mode never fetches
  /// profile XML, and every write needs those bytes to archive the live version before it
  /// overwrites or deletes it. Substituting here (and saying so on screen) is the difference
  /// between a dialog that works and one that spends a process spawn to print a flag error the
  /// operator reads as "apply is broken". The store refuses the combination too — this is the
  /// half that stops it ever being built.
  static AbctlRefresh _applyRefresh(AbctlRefresh planned) =>
      planned == AbctlRefresh.metadataOnly ? AbctlRefresh.smart : planned;

  // -----------------------------------------------------------------------------------------
  // actions
  // -----------------------------------------------------------------------------------------

  Future<void> _apply(ApplyOptions options) =>
      ref.read(gitopsProvider.notifier).applyPlan(options);

  /// Close, then recompute the plan against the tenant this run just changed.
  ///
  /// In that order: the recompute is a minutes-long tenant read that narrates into the run strip,
  /// and watching it from behind a modal sheet is watching nothing. The notifier and the
  /// navigator are both captured before the first await for the usual reason — this `State` may
  /// be gone by the time the pop completes.
  void _refreshAndClose() {
    final GitopsStore store = ref.read(gitopsProvider.notifier);
    Navigator.of(context).pop();
    unawaited(store.refreshPlan());
  }

  // -----------------------------------------------------------------------------------------
  // build
  // -----------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    // Selected, not watched whole: an apply publishes a new `GitopsState` on every transition,
    // and the plan table behind this dialog must not re-sort itself because a spinner moved.
    final PlanState plan = ref.watch(gitopsProvider.select((s) => s.plan));
    // The receipt belongs to the plan it ran against, and this dialog outlives neither. A run
    // that finished against an EARLIER plan is history the moment a recompute publishes a new
    // one: read whole, its terminal verdict banner would sit on top of rows it never saw, and —
    // because `canApply` is gated on `isTerminal` — Apply stayed dead for the rest of the
    // session, no matter how many times the plan was refreshed. Reopening the dialog did not
    // help either: this state lives in the store, not in the widget. So a stale run reads as
    // what it now is: nothing has been applied to what is on screen.
    final ApplyState stored = ref.watch(gitopsProvider.select((s) => s.apply));
    final ApplyState apply = stored.describes(plan.plan)
        ? stored
        : const ApplyState();
    final bool gitSourceOfTruth = ref.watch(
      gitopsProvider.select((s) => s.gitSourceOfTruth),
    );
    final AbctlRefresh refresh = ref.watch(
      gitopsProvider.select((s) => s.refresh),
    );
    final String? workspace = ref.watch(workspaceProvider);
    final String context_ = ref.watch(activeContextProvider);

    final ApplyOptions options = _options(
      gitSourceOfTruth: gitSourceOfTruth,
      refresh: refresh,
    );
    final List<PlanRow> rows = PlanRow.of(plan.plan);
    final _Removals removals = _Removals.of(plan.plan);
    final bool gated = _isGated(options, removals);
    final String phrase = _phrase(context_, workspace);

    return PopScope(
      // Escape must not dismiss a sheet whose command is mid-flight. The run would survive in the
      // store, but the outcome would have nowhere to land — and "did that finish?" is the one
      // question this screen exists to answer.
      canPop: !apply.isRunning,
      child: Dialog(
        backgroundColor: ab.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AbSpace.radius),
          side: BorderSide(color: ab.line),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 860,
            // Never taller than the window: a fixed height puts Apply below the fold on a
            // laptop, which on this screen means an operator scrolling to find the button that
            // writes to Apple Business.
            maxHeight: math.min(760, MediaQuery.sizeOf(context).height - 80),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(ab, apply, workspace, context_),
              Divider(height: 1, color: ab.line),
              // ABOVE the scroll view, never inside it: the outcome of a tenant write must not be
              // something the reader can scroll past. The Swift original put its failure line
              // last, under a log pane that had just grown by fifty lines, so a total failure
              // could be reported somewhere nobody looked.
              if (apply.verdict != ApplyVerdict.idle)
                _VerdictBanner(state: apply, onRefresh: _refreshAndClose),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AbSpace.md),
                  child: _body(
                    ab,
                    plan: plan,
                    apply: apply,
                    rows: rows,
                    removals: removals,
                    options: options,
                    gitSourceOfTruth: gitSourceOfTruth,
                    refresh: refresh,
                    workspace: workspace,
                  ),
                ),
              ),
              Divider(height: 1, color: ab.line),
              // Outside the scroll view on purpose: every control above rewrites this line, and a
              // command you have to scroll to cannot be watched changing.
              _CommandPreview(options: options, workspace: workspace),
              _footer(
                ab,
                apply: apply,
                options: options,
                rows: rows,
                gated: gated,
                phrase: phrase,
                subject: _gateSubject(
                  options: options,
                  removals: removals,
                  phrase: phrase,
                ),
                workspace: workspace,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------------------------
  // chrome
  // -----------------------------------------------------------------------------------------

  Widget _header(
    AbColors ab,
    ApplyState apply,
    String? workspace,
    String context_,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbSpace.md,
        AbSpace.md,
        AbSpace.sm,
        AbSpace.sm,
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
                  'Apply to Apple Business',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: ab.text,
                  ),
                ),
                Tooltip(
                  message: workspace ?? 'No workspace chosen',
                  child: MonoText(
                    // WHICH tenant and WHICH tree, together, in the header of the one screen
                    // where getting either wrong is expensive. An empty context is abctl's own
                    // current one, and saying so beats printing nothing.
                    '${context_.isEmpty ? "abctl's current context" : context_}'
                    '  ·  ${workspace == null ? 'no workspace' : folderLabel(workspace)}',
                    size: 11,
                    color: ab.faint,
                  ),
                ),
              ],
            ),
          ),
          if (apply.startedAt != null) ...<Widget>[
            // The live reading is what separates "still working" from "wedged" during a run that
            // legitimately takes minutes. It freezes the moment the run ends, and the ticker
            // retires its own timer then — see `ElapsedTicker`.
            ElapsedTicker(
              startedAt: apply.startedAt!,
              finishedAt: apply.finishedAt,
            ),
            const SizedBox(width: AbSpace.sm),
          ],
          if (apply.isRunning)
            ToolbarButton(
              icon: abIcon('stop.circle'),
              label: 'Cancel',
              weight: AbToolbarWeight.titled,
              tooltip:
                  'Stop the running abctl. It writes one configuration at a time, so anything '
                  'already sent to Apple Business stays — stopping does not undo it.',
              onPressed: () => ref.read(gitopsProvider.notifier).cancelApply(),
            ),
        ],
      ),
    );
  }

  Widget _footer(
    AbColors ab, {
    required ApplyState apply,
    required ApplyOptions options,
    required List<PlanRow> rows,
    required bool gated,
    required String phrase,
    required String subject,
    required String? workspace,
  }) {
    // `phrase.isNotEmpty` is not paranoia about a case that cannot happen — it is the direction
    // the failure has to fall. With no context and no workspace there is nothing to type, and an
    // empty field would then MATCH an empty phrase and open the gate by default.
    //
    // The subject check is the other half: the phrase says WHO, and `_confirmedFor` says what it
    // was said about. See [_confirmedFor] for the escalation it closes.
    final bool confirmed =
        !gated ||
        (phrase.isNotEmpty &&
            _typed.trim() == phrase &&
            _confirmedFor == subject);
    // One apply per PLAN. After a terminal outcome the counts above describe a tenant that has
    // since changed, so a second press would be approving numbers that are no longer true; the
    // way back is the recompute, which is what the button beside it does — and `apply` is scoped
    // to the plan on screen, so the recompute genuinely re-arms this.
    //
    // `didRun` is the other half, and the store learned it first: a pre-flight refusal (no
    // workspace chosen, another command running) reaches a terminal verdict without abctl ever
    // being spawned. Nothing was spent, so nothing may be locked — without this, one refusal
    // disabled Apply and hid the confirmation field beneath it, leaving no way back at all.
    final bool spent = apply.spent;
    final bool canApply =
        !apply.isRunning &&
        !spent &&
        workspace != null &&
        rows.isNotEmpty &&
        confirmed;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbSpace.md,
        AbSpace.sm,
        AbSpace.md,
        AbSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // `spent`, not `isTerminal`: a refusal that never spawned abctl must leave the gate it
          // hides behind reachable, or the operator is left with a disabled button and no field
          // to satisfy it.
          if (gated && !spent) ...<Widget>[
            // `confirmed` rather than a second `_typed == phrase` here: the tick and the green
            // border must agree with the button, and a field that reads "Confirmed" beside a
            // disabled Apply is a bug report waiting to be filed.
            _confirmationField(
              ab,
              phrase,
              matched: confirmed,
              enabled: !apply.isRunning,
            ),
            const SizedBox(height: AbSpace.sm),
          ],
          Row(
            children: <Widget>[
              // Pairs with the disabled button: whenever Apply is off because there is nothing to
              // apply, this is the sentence that says so.
              if (rows.isEmpty && !spent)
                Expanded(
                  child: Text(
                    'Nothing is pending — there is no plan to apply.',
                    style: TextStyle(fontSize: 11.5, color: ab.faint),
                  ),
                )
              else
                const Spacer(),
              if (apply.isTerminal) ...<Widget>[
                ToolbarButton(
                  icon: abIcon('arrow.clockwise'),
                  label: 'Refresh Plan',
                  weight: AbToolbarWeight.titled,
                  tooltip:
                      'Close this and recompute the plan against the tenant as it is now. After '
                      'a write — or a run that stopped part way through one — this is the only '
                      'thing that can say what is left pending.',
                  onPressed: _refreshAndClose,
                ),
                const SizedBox(width: AbSpace.sm),
              ],
              TextButton(
                // "Close" once the run has reached an outcome, INCLUDING a failed one: keyed off
                // the receipt alone, a terminal failure left the Swift sheet offering to cancel
                // something that had already happened.
                onPressed: apply.isRunning
                    ? null
                    : () => Navigator.of(context).pop(),
                child: Text(apply.isTerminal ? 'Close' : 'Cancel'),
              ),
              const SizedBox(width: AbSpace.sm),
              FilledButton(
                onPressed: canApply ? () => unawaited(_apply(options)) : null,
                style: FilledButton.styleFrom(
                  // The one control in the app that is drawn in the danger colour. A destructive
                  // apply must not look like every other primary button on the accent.
                  backgroundColor: options.prune ? ab.danger : ab.accent,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                ),
                child: Text(apply.isRunning ? 'Applying…' : 'Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The typed gate: the tenant's own name, or the workspace folder's when no context is named.
  ///
  /// **Trimmed and case-SENSITIVE, and the asymmetry is deliberate.** Trailing whitespace is a
  /// paste artefact and says nothing about intent; case is part of the name, and a gate that
  /// accepts `prod` for `Prod` is a gate that accepts a guess. The comparison lives in the caller
  /// ([_footer]) so the button's enablement and this field's own affordance read the same value.
  Widget _confirmationField(
    AbColors ab,
    String phrase, {
    required bool matched,
    required bool enabled,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text.rich(
          TextSpan(
            children: <InlineSpan>[
              TextSpan(
                text: 'This run can remove live configuration. Type ',
                style: TextStyle(fontSize: 12, color: ab.text),
              ),
              TextSpan(
                text: phrase,
                style: AbType.mono(
                  context,
                  size: 12,
                  color: ab.danger,
                  weight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: ' to enable Apply.',
                style: TextStyle(fontSize: 12, color: ab.text),
              ),
            ],
          ),
        ),
        const SizedBox(height: AbSpace.xs),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _confirm,
                enabled: enabled,
                autocorrect: false,
                enableSuggestions: false,
                // A name is one line. Enter must not be a second way to fire a destructive write
                // — the button is the gate, and it is the only thing that starts one.
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.deny(RegExp(r'\n')),
                ],
                style: AbType.mono(context, size: 12.5),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: phrase,
                  hintStyle: AbType.mono(context, size: 12.5, color: ab.faint),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AbSpace.sm,
                    vertical: AbSpace.sm,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AbSpace.radius),
                    borderSide: BorderSide(color: matched ? ab.ok : ab.danger),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AbSpace.radius),
                    borderSide: BorderSide(
                      color: matched ? ab.ok : ab.danger,
                      width: 2,
                    ),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AbSpace.radius),
                    borderSide: BorderSide(color: ab.line),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AbSpace.sm),
            // Spoken as well as tinted: the border colour is the only other difference between
            // "typed correctly" and "not yet", and colour alone is not a channel.
            Semantics(
              label: matched ? 'Confirmed' : 'Not confirmed',
              child: Icon(
                abIcon(matched ? 'checkmark.circle' : 'xmark.circle'),
                size: 16,
                color: matched ? ab.ok : ab.faint,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // -----------------------------------------------------------------------------------------
  // body
  // -----------------------------------------------------------------------------------------

  Widget _body(
    AbColors ab, {
    required PlanState plan,
    required ApplyState apply,
    required List<PlanRow> rows,
    required _Removals removals,
    required ApplyOptions options,
    required bool gitSourceOfTruth,
    required AbctlRefresh refresh,
    required String? workspace,
  }) {
    final ApplyResult? result = apply.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _ConsequenceSummary(rows: rows, plan: plan),
        if (options.prune || removals.total > 0) ...<Widget>[
          const SizedBox(height: AbSpace.md),
          _RemovalBlock(
            removals: removals,
            permitted: options.prune,
            gitSourceOfTruth: gitSourceOfTruth,
          ),
        ],
        // `spent` for the same reason the confirmation field uses it: a refusal changed nothing,
        // and the options it refused are what the operator is most likely to want to adjust.
        if (!apply.spent && !apply.isRunning) ...<Widget>[
          const SizedBox(height: AbSpace.lg),
          _optionsSection(ab, gitSourceOfTruth, refresh),
        ],
        if (apply.isRunning || apply.transcript.isNotEmpty) ...<Widget>[
          const SizedBox(height: AbSpace.lg),
          _TranscriptPane(state: apply),
        ],
        if (result != null) ...<Widget>[
          const SizedBox(height: AbSpace.lg),
          _ResultsPane(state: apply, result: result),
        ],
        // Only where there is no receipt: when a sync half-applied, the failure's own details ARE
        // the failed rows, and the results pane above already lists every one of them with its
        // status. Printing the same failures twice, in two formats, on the one screen that has to
        // be read carefully is how the Swift log blob became unreadable.
        if (result == null && apply.failure != null) ...<Widget>[
          const SizedBox(height: AbSpace.lg),
          _FailureDetail(failure: apply.failure!),
        ],
      ],
    );
  }

  Widget _optionsSection(
    AbColors ab,
    bool gitSourceOfTruth,
    AbctlRefresh refresh,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('Options', style: AbType.label(context)),
        const SizedBox(height: AbSpace.sm),
        if (gitSourceOfTruth)
          // No control at all, because there is no choice to offer. The plan on screen was
          // computed with git as the complete desired state; applying it without removals would
          // execute half of it and leave the other half proposed again on the next run forever —
          // which is why `ApplyOptions` cannot even express that combination.
          AbNote(
            icon: abIcon('lock'),
            tone: AbSeverity.drift,
            text:
                'Git is the source of truth for this plan, so this run removes whatever Apple '
                'Business has that gitops/ does not declare. That is what the mode means, and it '
                'is not separately optional — switch the Diff screen to two-way and recompute if '
                'you want an additive reconcile.',
          )
        else
          Row(
            children: <Widget>[
              ToolbarButton(
                icon: abIcon(
                  _policy == _RemovalPolicy.allow ? 'trash' : 'lock',
                ),
                label: _policy == _RemovalPolicy.allow
                    ? 'Removals allowed'
                    : 'Removals off',
                weight: AbToolbarWeight.titled,
                selected: _policy == _RemovalPolicy.allow,
                tooltip: _policy == _RemovalPolicy.allow
                    ? 'This run may DELETE live configurations that git no longer has, and detach '
                          'blueprint members git no longer lists. Turn it off to apply only the '
                          'additive half of the plan.'
                    : 'This run adds and updates only. Rows that would remove something are '
                          'reported by abctl and skipped — they will still be pending afterwards.',
                onPressed: () {
                  setState(
                    () => _policy = _policy == _RemovalPolicy.allow
                        ? _RemovalPolicy.keep
                        : _RemovalPolicy.allow,
                  );
                  // Emptying the field is the visible half of the re-arm. `_confirmedFor` alone
                  // would already close the gate (see [_confirmedFor]), but it would leave the
                  // tenant's name sitting in a box under a disabled button with no explanation —
                  // and "why is Apply greyed out, I typed it" is how a safety control gets
                  // reported as a bug and then removed. Clearing runs the listener, which restamps
                  // `_confirmedFor` against the toggle's new state; `_typed` is empty by then, so
                  // the gate stays shut either way.
                  _confirm.clear();
                },
              ),
              const SizedBox(width: AbSpace.md),
              Expanded(
                child: Text(
                  _policy == _RemovalPolicy.allow
                      ? 'Deletes and detaches will be executed.'
                      : 'Nothing will be deleted or detached.',
                  style: TextStyle(fontSize: 11.5, color: ab.dim),
                ),
              ),
            ],
          ),
        const SizedBox(height: AbSpace.sm),
        Row(
          children: <Widget>[
            _VerifyButton(
              mode: _verify,
              onChanged: (AbctlVerify mode) => setState(() => _verify = mode),
            ),
            const SizedBox(width: AbSpace.md),
            Text('Limit writes', style: TextStyle(fontSize: 12, color: ab.dim)),
            const SizedBox(width: AbSpace.sm),
            SizedBox(
              width: 96,
              child: TextField(
                controller: _limit,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                style: AbType.mono(context, size: 12.5),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'unlimited',
                  hintStyle: AbType.mono(context, size: 11.5, color: ab.faint),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AbSpace.sm,
                    vertical: 6,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AbSpace.radius),
                    borderSide: BorderSide(color: ab.line),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AbSpace.sm),
            Expanded(
              child: Text(
                'Circuit breaker: abctl stops after this many tenant writes.',
                style: TextStyle(fontSize: 11, color: ab.faint),
              ),
            ),
          ],
        ),
        if (refresh == AbctlRefresh.metadataOnly) ...<Widget>[
          const SizedBox(height: AbSpace.sm),
          AbNote(
            icon: abIcon('exclamationmark.triangle'),
            tone: AbSeverity.drift,
            text:
                'This plan was computed with the metadata-only re-read, which abctl will not '
                'apply: it never fetches profile XML, and every write needs those bytes to '
                'archive the live version before overwriting or deleting it. This run uses the '
                'smart re-read instead — the command below says so.',
          ),
        ],
      ],
    );
  }

  // -----------------------------------------------------------------------------------------
  // the gate
  // -----------------------------------------------------------------------------------------

  /// Whether Apply needs the tenant's name typed first.
  ///
  /// **The union of what the COMMAND permits and what the PLAN proposes, and it has to be the
  /// union.** Either half alone leaves a hole:
  ///
  ///  * A run that permits removals is gated even when the plan on screen lists none, because
  ///    abctl re-reads the tenant at apply time — anything that appeared in Apple Business since
  ///    the plan was computed, and is absent from git, is removed by this run without ever having
  ///    been a row anybody read.
  ///  * A plan that proposes removals is gated even when this run would skip them, because a
  ///    reader who has just been shown "2 remove" is one toggle away from executing them, and the
  ///    gate is what makes that a decision rather than a click.
  static bool _isGated(ApplyOptions options, _Removals removals) =>
      options.prune || removals.total > 0;

  /// What has to be typed: the context name, or the workspace folder when abgui is running
  /// against abctl's own current context.
  ///
  /// The fallback is not a weakening. An unnamed context is abctl's default one, and there is no
  /// tenant name in the app to type — but the folder IS the desired state being pushed, and
  /// naming it is the same act of deliberate identification. Which one is being asked for is
  /// stated in the field's label, so nobody is left guessing what to type.
  static String _phrase(String context, String? workspace) {
    if (context.isNotEmpty) return context;
    return workspace == null ? '' : folderLabel(workspace);
  }
}

/// Whether a two-way reconcile may remove things. Under git-as-truth the question does not exist.
enum _RemovalPolicy { keep, allow }

// ---------------------------------------------------------------------------------------------
// what this plan removes
// ---------------------------------------------------------------------------------------------

/// The removals a plan proposes, counted the three ways they differ in what they cost.
///
/// Three numbers rather than one, because the recoveries are not the same: a deleted
/// CONFIGURATION is archived by abctl before it goes and can be restored; a DETACHED member is
/// not archived (there is no profile to file — re-attaching is the undo); a dropped LOCAL file is
/// a working-tree change, which is git's to restore, not Apple's. A single "3 removals" would
/// invite one answer to three different questions.
@immutable
class _Removals {
  const _Removals({
    required this.configs,
    required this.members,
    required this.localFiles,
  });

  /// `delete-abm`: a configuration profile deleted from the live tenant.
  final int configs;

  /// `detach-*`: a member removed from a blueprint in Apple Business.
  final int members;

  /// `delete-git`: a file dropped from the local `gitops/` tree.
  final int localFiles;

  int get total => configs + members + localFiles;

  /// Anything that changes Apple Business, as opposed to the working tree.
  int get tenant => configs + members;

  static _Removals of(Plan? plan) {
    if (plan == null) {
      return const _Removals(configs: 0, members: 0, localFiles: 0);
    }
    return _Removals(
      configs: plan.configs
          .where((ConfigChange c) => c.action == 'delete-abm')
          .length,
      // Actionable only: a blocked row is one abctl cannot perform, and counting it here would
      // put a number in the danger block that no run can produce.
      members: plan.blueprints
          .where((BlueprintChange b) => b.isDetach && b.isActionable)
          .length,
      localFiles: plan.configs
          .where((ConfigChange c) => c.action == 'delete-git')
          .length,
    );
  }
}

// ---------------------------------------------------------------------------------------------
// pieces
// ---------------------------------------------------------------------------------------------

/// The counts, by consequence — the first thing read and the last thing that should be wrong.
class _ConsequenceSummary extends StatelessWidget {
  const _ConsequenceSummary({required this.rows, required this.plan});

  final List<PlanRow> rows;
  final PlanState plan;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Map<PlanConsequence, int> counts = PlanRow.countByConsequence(rows);
    final int blocked = rows.where((PlanRow row) => row.blocked).length;
    final int local = rows.where((PlanRow row) => row.writesTree).length;
    final int tenant = rows.length - local;

    if (rows.isEmpty) {
      return AbNote(
        icon: abIcon('checkmark.seal'),
        tone: AbSeverity.ok,
        text: plan.hasPlan
            ? 'Git and the tenant agree: there is nothing to apply.'
            : 'No plan has been computed for this workspace yet, so there is nothing to apply.',
      );
    }

    return Column(
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
            for (final PlanConsequence consequence in PlanConsequence.values)
              if ((counts[consequence] ?? 0) > 0)
                Tooltip(
                  message: consequence.explanation,
                  child: AbBadge(
                    label: '${counts[consequence]} ${consequence.countWord}',
                    severity: consequence.severity,
                  ),
                ),
            if (blocked > 0)
              Tooltip(
                message:
                    'Counted above as well, deliberately — the counts have to add up to the plan. '
                    'abctl reports these but cannot perform them: an attach whose member does not '
                    'exist in Apple Business has no id to attach.',
                child: AbBadge(label: '$blocked blocked'),
              ),
          ],
        ),
        const SizedBox(height: AbSpace.xs),
        Text(
          // Not every applicable row is a tenant write: a pull writes gitops/lib and an adopt
          // writes a blueprint manifest. Saying "applied to Apple Business" over a plan that only
          // touches local files misdescribes what the button does.
          _scope(tenant, local),
          style: TextStyle(fontSize: 11.5, color: ab.dim),
        ),
        if (plan.checkedAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              // The stamp matters more here than on the Diff screen: this is the moment the rows
              // stop being a description and become instructions, and abctl re-reads the tenant
              // when it runs — so a plan computed an hour ago is not what will be applied.
              'Plan computed ${AbRelativeTime.absolute(plan.checkedAt!)}. abctl re-reads the '
              'tenant when it applies, so what runs is recomputed from git at that moment.',
              style: TextStyle(fontSize: 11, color: ab.faint),
            ),
          ),
      ],
    );
  }

  static String _scope(int tenant, int local) {
    if (tenant == 0) {
      return '$local of them write gitops/ locally; Apple Business is not written at all.';
    }
    if (local == 0) {
      return '$tenant of them write Apple Business.';
    }
    return '$tenant of them write Apple Business; $local write gitops/ locally.';
  }
}

/// The danger block: what this run can remove, how much of it comes back, and from where.
class _RemovalBlock extends StatelessWidget {
  const _RemovalBlock({
    required this.removals,
    required this.permitted,
    required this.gitSourceOfTruth,
  });

  final _Removals removals;

  /// Whether the command as configured actually permits removals. False here means the plan
  /// proposes some and this run would SKIP them, which is a different sentence.
  final bool permitted;

  final bool gitSourceOfTruth;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final AbSeverity tone = permitted ? AbSeverity.danger : AbSeverity.drift;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AbSpace.md),
      decoration: BoxDecoration(
        color: tone.ground(ab),
        border: Border.all(color: tone.edge(ab)),
        borderRadius: BorderRadius.circular(AbSpace.radius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            label: permitted ? 'Destructive' : 'Removals skipped',
            child: Icon(
              abIcon(permitted ? 'exclamationmark.triangle.fill' : 'lock'),
              size: 20,
              color: tone.ink(ab),
            ),
          ),
          const SizedBox(width: AbSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SelectableText(
                  _headline(),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ab.text,
                  ),
                ),
                const SizedBox(height: AbSpace.xs),
                for (final String line in _lines())
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: SelectableText(
                      line,
                      style: TextStyle(fontSize: 12, color: ab.dim),
                    ),
                  ),
                if (permitted) ...<Widget>[
                  const SizedBox(height: AbSpace.sm),
                  SelectableText(
                    // The reversibility claim, scoped exactly to what abctl actually archives
                    // (`internal/reconcile/apply.go`: archiving always precedes the write it
                    // protects, and a failed archive SKIPS the write to preserve the audit
                    // trail). Overstating this is worse than omitting it — an operator who
                    // believes a detach is recoverable finds out otherwise at the worst moment.
                    'Every configuration abctl overwrites or deletes is archived to '
                    'gitops/archive/ first, so those are recoverable from the Archive screen. A '
                    'detached member is not archived — re-attaching it is the undo. A file '
                    'removed from gitops/ is a working-tree change, so git restores it.',
                    style: TextStyle(fontSize: 11.5, color: ab.dim),
                  ),
                  const SizedBox(height: AbSpace.sm),
                  SelectableText(
                    // The reason the typed gate is armed even when the counts above are zero.
                    'abctl recomputes the plan when it runs. Anything that has appeared in Apple '
                    'Business since this plan was computed, and that gitops/ does not declare, '
                    'will be removed by this run too — it is not limited to the rows above.',
                    style: TextStyle(fontSize: 11.5, color: ab.faint),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _headline() {
    if (!permitted) {
      return removals.total == 1
          ? 'This run skips the 1 removal in the plan'
          : 'This run skips the ${removals.total} removals in the plan';
    }
    if (removals.tenant == 0) {
      return gitSourceOfTruth
          ? 'This run may delete live configuration'
          : 'Removals are enabled for this run';
    }
    return removals.tenant == 1
        ? 'This run removes 1 thing from Apple Business'
        : 'This run removes ${removals.tenant} things from Apple Business';
  }

  List<String> _lines() {
    final List<String> lines = <String>[];
    if (removals.configs > 0) {
      lines.add(
        removals.configs == 1
            ? '1 configuration profile deleted from Apple Business.'
            : '${removals.configs} configuration profiles deleted from Apple Business.',
      );
    }
    if (removals.members > 0) {
      lines.add(
        removals.members == 1
            ? '1 member detached from a blueprint.'
            : '${removals.members} members detached from their blueprints.',
      );
    }
    if (removals.localFiles > 0) {
      lines.add(
        removals.localFiles == 1
            ? '1 file removed from the local gitops/ tree.'
            : '${removals.localFiles} files removed from the local gitops/ tree.',
      );
    }
    if (lines.isEmpty && permitted) {
      lines.add(
        'The plan on screen lists no removals — but this command permits them, and the tenant is '
        'read again when it runs.',
      );
    }
    if (!permitted) {
      lines.add(
        'They stay pending, and the next plan will propose them again.',
      );
    }
    return lines;
  }
}

/// The verdict, pinned where it cannot be scrolled away.
///
/// Six states, one banner, and the symbol carries the distinction as well as the tint: "nothing
/// landed", "some of it landed" and "we cannot say what landed" are three different situations to
/// be in, and the glyph is the fastest way to tell them apart.
class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.state, required this.onRefresh});

  final ApplyState state;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final AbSeverity tone = _tone(state.verdict);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AbSpace.md),
      decoration: BoxDecoration(
        color: tone.ground(ab),
        border: Border(bottom: BorderSide(color: ab.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 22,
            child: Semantics(
              label: _spoken(state.verdict),
              child: state.verdict == ApplyVerdict.running
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: ab.accent,
                      ),
                    )
                  : Icon(
                      abIcon(_symbol(state.verdict)),
                      size: 20,
                      color: tone.ink(ab),
                    ),
            ),
          ),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SelectableText(
                  headline(state),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tone.ink(ab),
                  ),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  detail(state),
                  style: TextStyle(fontSize: 11.5, color: ab.dim),
                ),
              ],
            ),
          ),
          if (state.verdict == ApplyVerdict.unknown) ...<Widget>[
            const SizedBox(width: AbSpace.sm),
            ToolbarButton(
              icon: abIcon('arrow.clockwise'),
              label: 'Refresh Plan',
              weight: AbToolbarWeight.titled,
              tooltip:
                  'Recompute the plan. It is the only thing that can say which of these writes '
                  'reached Apple Business.',
              onPressed: onRefresh,
            ),
          ],
          // Only where there is something to copy: a clean apply and a run still in flight get no
          // button rather than one that copies "everything worked".
          if (state.verdict == ApplyVerdict.partial ||
              state.verdict == ApplyVerdict.failed ||
              state.verdict == ApplyVerdict.unknown) ...<Widget>[
            const SizedBox(width: AbSpace.sm),
            CopyButton(
              text: () => copyText(state),
              label: 'Copy Error',
              weight: AbToolbarWeight.titled,
              tooltip:
                  'Copy the verdict, its details and every failed row as one paste, for a ticket. '
                  'The complete transcript is also in this run\'s log file.',
            ),
          ],
        ],
      ),
    );
  }

  static AbSeverity _tone(ApplyVerdict verdict) => switch (verdict) {
    ApplyVerdict.idle || ApplyVerdict.running => AbSeverity.neutral,
    ApplyVerdict.applied => AbSeverity.ok,
    // Amber, not red: "some of it landed" is a state to work from, and painting it the same as a
    // total failure loses the distinction the operator needs most.
    ApplyVerdict.partial || ApplyVerdict.unknown => AbSeverity.drift,
    ApplyVerdict.failed => AbSeverity.danger,
  };

  static String _symbol(ApplyVerdict verdict) => switch (verdict) {
    ApplyVerdict.applied => 'checkmark.seal.fill',
    ApplyVerdict.partial => 'exclamationmark.triangle.fill',
    ApplyVerdict.unknown => 'questionmark.circle',
    ApplyVerdict.failed => 'xmark.octagon.fill',
    _ => 'circle',
  };

  static String _spoken(ApplyVerdict verdict) => switch (verdict) {
    ApplyVerdict.running => 'Applying',
    ApplyVerdict.applied => 'Applied',
    ApplyVerdict.partial => 'Partly applied',
    ApplyVerdict.unknown => 'Outcome unknown',
    ApplyVerdict.failed => 'Failed',
    ApplyVerdict.idle => 'Not started',
  };

  /// The one line that cannot be scrolled away. Public and static so a test can pin the sentences
  /// themselves — they are the product here, not decoration.
  static String headline(ApplyState state) {
    final ApplyResult? result = state.result;
    switch (state.verdict) {
      case ApplyVerdict.idle:
        return 'Nothing has been applied yet.';
      case ApplyVerdict.running:
        return 'Applying to Apple Business…';
      case ApplyVerdict.applied:
        return 'Applied ${result?.totalWrites ?? 0} change(s)';
      case ApplyVerdict.partial:
        // Never print the count blindly. A run whose every row is `done` and whose counters are 0
        // can STILL have failed — that is precisely the case this screen exists to surface, and
        // "Applied 3, 0 failed" is the one sentence here that must never appear.
        final int failed = state.failedCount;
        if (failed > 0) {
          return 'Applied ${result?.totalWrites ?? 0}, $failed failed';
        }
        return 'Applied ${result?.totalWrites ?? 0}, but the run FAILED';
      case ApplyVerdict.unknown:
        return 'Stopped part way through — some changes may have landed';
      case ApplyVerdict.failed:
        return 'Nothing was applied';
    }
  }

  /// The evidence under the headline: abctl's own sentence first, then what to do about it.
  static String detail(ApplyState state) {
    final ApplyResult? result = state.result;
    final SyncFailure? failure = state.failure;
    switch (state.verdict) {
      case ApplyVerdict.idle:
        return 'Review the plan and the command below, then apply.';
      case ApplyVerdict.running:
        return state.transcript.isNotEmpty
            ? state.transcript.last
            : 'Writing to the tenant — leave this open until it finishes.';
      case ApplyVerdict.applied:
        final List<String> parts = <String>[
          '${result?.totalWrites ?? 0} write(s)',
          if ((result?.totalSkipped ?? 0) > 0)
            '${result!.totalSkipped} skipped',
          'nothing failed',
        ];
        final Verification? verification = result?.verification;
        // abctl's own STRUCTURED verdict, not a phrase scraped from its narration: a write Apple
        // acknowledged and then dropped shows up here and in none of the counters above.
        if (verification != null) parts.add(verification.headline);
        return parts.join(' — ');
      case ApplyVerdict.partial:
        final List<String> parts = <String>[
          failure?.headline ?? '${state.failedCount} write(s) failed',
          if ((result?.totalSkipped ?? 0) > 0)
            '${result!.totalSkipped} skipped',
          // Point at the pane that actually holds the evidence. With no failed rows every row in
          // Results is green, and sending the reader there to find the failure is misdirection.
          state.failedCount > 0
              ? 'Results below lists every outcome'
              : 'every change reported done — the reason is in the transcript below and in the '
                    'run log',
        ];
        return parts.join(' — ');
      case ApplyVerdict.unknown:
        return '${failure?.headline ?? 'The run ended without reporting.'} abctl writes one '
            'configuration at a time and had no chance to say which ones it had already sent, so '
            'the tenant may now be part way between git and where it started. Refresh the plan to '
            'find out what is actually pending.';
      case ApplyVerdict.failed:
        // A receipt-less exit is abctl's contract for "it stopped before writing" — it prints the
        // per-item document and only then exits non-zero — so the claim above is safe. Saying WHY
        // it is safe belongs here rather than in a comment nobody reading the screen can see.
        return '${failure?.headline ?? 'abctl sync --apply did not complete.'} abctl prints its '
            'per-item receipt before exiting, so a run that produced none stopped before it wrote '
            'anything.';
    }
  }

  /// The whole failure as one paste: the verdict, the evidence, and every failed row.
  static String copyText(ApplyState state) {
    final List<String> parts = <String>[headline(state), detail(state)];
    final String details = state.failure?.details.trim() ?? '';
    if (details.isNotEmpty) {
      parts.add(details);
    } else {
      final List<OutcomeRow> failed =
          state.result?.rows.where((OutcomeRow row) => row.failed).toList() ??
          const <OutcomeRow>[];
      if (failed.isNotEmpty) {
        parts.add(
          failed
              .map(
                (OutcomeRow row) => '${row.action} ${row.name} — ${row.detail}',
              )
              .join('\n'),
        );
      }
    }
    return parts.join('\n\n');
  }
}

/// abctl's live narration, and the frozen copy of it afterwards.
///
/// **Two sources, one pane, and the switch is what keeps the evidence readable.** While the run
/// is in flight the lines come straight off `ProgressSink`'s notifier through a
/// `ValueListenableBuilder` — that is the whole reason the sink is not a provider: abctl narrates
/// per configuration, and publishing each line through Riverpod would invalidate every dependent
/// once per line on the thread that also has to draw (the bug that blanked the Swift window).
/// Once the run ends the pane reads [ApplyState.transcript] instead, because the sink belongs to
/// whatever runs next and the recompute that follows an apply would empty it while the operator
/// was still reading it.
class _TranscriptPane extends ConsumerWidget {
  const _TranscriptPane({required this.state});

  final ApplyState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('Progress', style: AbType.label(context)),
            const Spacer(),
            CopyButton(
              text: () => state.isRunning
                  ? ref.read(progressSinkProvider).lines.value.join('\n')
                  : state.transcript.join('\n'),
              weight: AbToolbarWeight.compact,
              tooltip:
                  'Copy everything abctl has printed. The complete, untrimmed transcript is also '
                  'written to this run\'s log file.',
            ),
          ],
        ),
        const SizedBox(height: AbSpace.xs),
        Container(
          height: 180,
          decoration: BoxDecoration(
            color: ab.sunken,
            border: Border.all(color: ab.lineSoft),
            borderRadius: BorderRadius.circular(AbSpace.radius),
          ),
          padding: const EdgeInsets.all(AbSpace.sm),
          child: state.isRunning
              ? ValueListenableBuilder<List<String>>(
                  valueListenable: ref.watch(progressSinkProvider).lines,
                  builder:
                      (
                        BuildContext context,
                        List<String> lines,
                        Widget? child,
                      ) => _transcript(context, ab, lines, follow: true),
                )
              : _transcript(context, ab, state.transcript, follow: false),
        ),
      ],
    );
  }

  Widget _transcript(
    BuildContext context,
    AbColors ab,
    List<String> lines, {
    required bool follow,
  }) {
    if (lines.isEmpty) {
      return Text(
        'Waiting for abctl…',
        style: AbType.mono(context, size: 11, color: ab.faint),
      );
    }
    // One selectable block rather than a stack of Texts: this is what gets pasted into a ticket,
    // and a transcript that cannot be selected across lines cannot be pasted at all. `reverse`
    // keeps the newest line in view while the run is live; a finished transcript opens at the
    // TOP, because its first line is usually where the failure began.
    return SingleChildScrollView(
      reverse: follow,
      // A dialog must not claim the window's primary scroll controller — the Diff screen's own
      // transcript is alive behind this one.
      primary: false,
      child: SelectableText(
        lines.join('\n'),
        style: AbType.mono(context, size: 11, color: ab.dim),
      ),
    );
  }
}

/// The per-item outcomes — successes AND failures, each with abctl's own words for it.
class _ResultsPane extends StatelessWidget {
  const _ResultsPane({required this.state, required this.result});

  final ApplyState state;
  final ApplyResult result;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Verification? verification = result.verification;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('Results', style: AbType.label(context)),
            const Spacer(),
            CopyButton(
              text: () => _asText(),
              weight: AbToolbarWeight.compact,
              tooltip:
                  'Copy every outcome row as text. Selecting twenty wrapped rows by hand is not a '
                  'copy affordance.',
            ),
          ],
        ),
        const SizedBox(height: AbSpace.xs),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: ab.lineSoft),
            borderRadius: BorderRadius.circular(AbSpace.radius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(AbSpace.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SelectableText(
                      '${result.totalWrites} write(s) · ${result.totalErrors} error(s) · '
                      '${result.totalSkipped} skipped',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: state.failedCount > 0 ? ab.danger : ab.ok,
                      ),
                    ),
                    if (verification != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: SelectableText(
                          verification.headline,
                          style: TextStyle(
                            fontSize: 11.5,
                            // Red only where abctl OBSERVED that a write did not land. "Could not
                            // be checked" is not the same claim and must not wear the same colour.
                            color: state.notPersisted ? ab.danger : ab.dim,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (result.rows.isNotEmpty) ...<Widget>[
                Divider(height: 1, color: ab.lineSoft),
                ConstrainedBox(
                  // Capped, and scrollable inside: a hundred outcomes must not push the command
                  // preview and the Close button off the bottom of the dialog.
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    primary: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final OutcomeRow row in _failuresFirst(
                          result.rows,
                        ))
                          _OutcomeLine(row: row),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _asText() {
    final List<String> lines = <String>[
      '${result.totalWrites} write(s) - ${result.totalErrors} error(s) - '
          '${result.totalSkipped} skipped',
      if (result.verification != null) result.verification!.headline,
      for (final OutcomeRow row in _failuresFirst(result.rows))
        '${row.status}: ${row.action} ${row.name} - ${row.detail}'
            '${row.archive == null ? '' : ' [archived: ${row.archive}]'}',
    ];
    return lines.join('\n');
  }

  /// Failed rows first, abctl's own order within a tier.
  ///
  /// The same rule the validation report follows, for the same reason: a run with two failures
  /// among ninety successes must not make the reader scroll to find them. Dart's `List.sort` is
  /// introsort and therefore NOT stable, so the original index is the tiebreak — within a tier
  /// abctl's order is meaningful and must not rearrange itself between two rebuilds of identical
  /// data.
  static List<OutcomeRow> _failuresFirst(List<OutcomeRow> rows) {
    final List<int> order = List<int>.generate(rows.length, (int i) => i);
    order.sort((int x, int y) {
      final int tier = _tier(rows[x]).compareTo(_tier(rows[y]));
      return tier != 0 ? tier : x - y;
    });
    return <OutcomeRow>[for (final int i in order) rows[i]];
  }

  static int _tier(OutcomeRow row) {
    if (row.failed) return 0;
    return row.status == 'skipped' ? 2 : 1;
  }
}

/// One outcome: what abctl did, to what, and what it said about it.
class _OutcomeLine extends StatelessWidget {
  const _OutcomeLine({required this.row});

  final OutcomeRow row;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final (
      String symbol,
      AbSeverity tone,
      String spoken,
    ) = switch (row.status) {
      'error' => ('xmark.circle', AbSeverity.danger, 'Failed'),
      'skipped' => ('minus.circle', AbSeverity.neutral, 'Skipped'),
      _ => ('checkmark.circle', AbSeverity.ok, 'Done'),
    };
    final String? archive = row.archive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AbSpace.sm, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ab.lineSoft)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The status is spoken as well as drawn: the glyph and its tint are the only difference
          // between a row that landed and one that did not.
          Semantics(
            label: spoken,
            child: Icon(abIcon(symbol), size: 14, color: tone.ink(ab)),
          ),
          const SizedBox(width: AbSpace.sm),
          SizedBox(
            width: 132,
            child: MonoText(row.action, size: 11, color: ab.dim),
          ),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SelectableText(
                  row.name,
                  style: TextStyle(fontSize: 12, color: ab.text),
                ),
                if (row.detail.isNotEmpty)
                  SelectableText(
                    row.detail,
                    // The failure's OWN message, in full and never truncated: it is the only
                    // account of what Apple refused, and a clipped "403 FORB…" is not one.
                    style: TextStyle(
                      fontSize: 11.5,
                      color: row.failed ? ab.danger : ab.dim,
                    ),
                  ),
                if (archive != null && archive.isNotEmpty)
                  // The receipt for the reversibility claim in the danger block above: this is
                  // the file the live version was filed into before it was overwritten.
                  SelectableText(
                    'archived: $archive',
                    style: AbType.mono(context, size: 10.5, color: ab.faint),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// abctl's long-form account of a run that produced no receipt.
class _FailureDetail extends StatelessWidget {
  const _FailureDetail({required this.failure});

  final SyncFailure failure;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final String details = failure.details.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('What abctl said', style: AbType.label(context)),
            const Spacer(),
            CopyButton(
              text: () => failure.copyableText,
              weight: AbToolbarWeight.compact,
              tooltip: 'Copy the failure and everything it was derived from.',
              enabled: details.isNotEmpty,
            ),
          ],
        ),
        const SizedBox(height: AbSpace.xs),
        if (details.isEmpty)
          Text(
            'abctl printed nothing beyond the message above.',
            style: TextStyle(fontSize: 11.5, color: ab.faint),
          )
        else
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 200),
            padding: const EdgeInsets.all(AbSpace.sm),
            decoration: BoxDecoration(
              color: ab.sunken,
              border: Border.all(color: ab.lineSoft),
              borderRadius: BorderRadius.circular(AbSpace.radius),
            ),
            // NOT scrolled to the bottom: this text is finished when it appears, and opening it
            // at the last line would hide the first thing that went wrong.
            child: SingleChildScrollView(
              primary: false,
              child: SelectableText(
                details,
                style: AbType.mono(context, size: 11, color: ab.dim),
              ),
            ),
          ),
      ],
    );
  }
}

/// The exact command Apply will run.
///
/// **Rendered from `previewArgv` of the same builder the client executes** — `previewArgv` IS
/// `AbctlArgs.preview`, and a contract test pins the pair to the same output, so this line cannot
/// become a lookalike when a flag changes on one side. Every control in this dialog visibly
/// rewrites it, which is what makes the options readable as a command rather than as settings.
class _CommandPreview extends ConsumerWidget {
  const _CommandPreview({required this.options, required this.workspace});

  final ApplyOptions options;
  final String? workspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    // Through the NARRATING client, because that is the one that will run it: it carries the same
    // context tail, so the tenant named here is the tenant written.
    final List<String> argv = ref
        .watch(narratingClientProvider)
        .previewArgv(AbctlArgs.syncApply(options));
    final String script = CommandFormatter.script(argv: argv, cwd: workspace);

    return Container(
      width: double.infinity,
      color: ab.raised,
      padding: const EdgeInsets.symmetric(
        horizontal: AbSpace.md,
        vertical: AbSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('This runs', style: AbType.label(context)),
              const Spacer(),
              CopyButton(
                text: () => script,
                weight: AbToolbarWeight.compact,
                tooltip: workspace == null
                    ? 'Copy this command to the clipboard.'
                    : 'Copy this command, with the cd into the workspace, to the clipboard.',
              ),
            ],
          ),
          const SizedBox(height: 2),
          // Monospaced, selectable, and on its own tinted ground: this is machine text an
          // administrator is being asked to approve, and it must not read as prose.
          SelectableText(
            CommandFormatter.line(argv),
            style: AbType.mono(context, size: 12, color: ab.text),
          ),
          const SizedBox(height: 2),
          Text(
            workspace == null
                ? 'The confirmation abctl would prompt for is the one you give by pressing Apply.'
                : 'Runs in ${folderLabel(workspace!)} — abctl resolves gitops/ against the '
                      'directory it runs in. The confirmation abctl would prompt for is the one '
                      'you give by pressing Apply.',
            style: TextStyle(fontSize: 10.5, color: ab.faint),
          ),
        ],
      ),
    );
  }
}

/// How much of what this run writes is read back afterwards.
///
/// A menu rather than a toggle because the three answers are not degrees of one setting: `none`
/// performs no check at all and therefore returns NO verdict, which is a different thing from a
/// clean one — Apple answers `2xx` to a write it then silently discards, and the read-back is the
/// only thing that catches it.
class _VerifyButton extends StatelessWidget {
  const _VerifyButton({required this.mode, required this.onChanged});

  final AbctlVerify mode;
  final ValueChanged<AbctlVerify> onChanged;

  static String _describe(AbctlVerify mode) => switch (mode) {
    AbctlVerify.targeted =>
      'Re-read just the configurations this run wrote. abctl\'s default.',
    AbctlVerify.full =>
      'Re-read every configuration and compare it against git. Slow on a large tenant.',
    AbctlVerify.none =>
      'No read-back and no verdict — NOT the same as a clean one.',
  };

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Color ink = mode == AbctlVerify.none ? ab.drift : ab.dim;
    return Tooltip(
      message:
          'What abctl checks after it writes. Apple returns 2xx for a PATCH it then declines to '
          'store, so "the write succeeded" and "the tenant matches git" are different '
          'claims.\n\n${_describe(mode)}',
      child: PopupMenuButton<AbctlVerify>(
        position: PopupMenuPosition.under,
        tooltip: '',
        onSelected: onChanged,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<AbctlVerify>>[
          for (final AbctlVerify option in AbctlVerify.values)
            PopupMenuItem<AbctlVerify>(
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
                'Verify',
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
