// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Blueprint membership: attach, detach, and adopt one configuration on one blueprint.
///
/// **Three verbs, two of which reach a live tenant and one of which does not.** `attach` and
/// `detach` change what Apple Business deploys to every device in the blueprint and then rewrite
/// the blueprint's manifest; `adopt` writes `gitops/blueprints/` and NOTHING else. Collapsing that
/// difference into three same-looking buttons is the mistake this file is arranged to prevent —
/// each verb states its consequence and carries a badge naming where it writes, and the gate
/// (`--yes`) is present for exactly the two that need one.
///
/// **Why `adopt` is here at all.** It is the answer to a real complaint: "there is no way to mark
/// a config as git-backed so it doesn't get detach-config". A configuration attached in Apple's
/// console is live-but-undeclared, so every reconcile proposes to detach it, forever, and no
/// button in the old GUI could clear that row. `adopt` records it in the manifest, which is what
/// makes the proposal go away. That is a sentence the UI has to say out loud, because "adopt" as a
/// word says none of it.
///
/// **Why the workspace is mandatory here.** abctl roots `gitops/` at its process working
/// directory. Run from anywhere else, all three verbs write their manifest into a different tree
/// or none — which is precisely how a green attach left git untouched and produced a
/// `detach-config` drift row that came back on every refresh. `AbctlClient` runs every verb in the
/// workspace, so the remaining hole is having no workspace at all: this dialog refuses to run
/// rather than write a manifest somewhere nobody will look.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/models/write_outcome.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/load_token.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/choice_card.dart';
import 'package:abgui/src/ui/widgets/command_preview.dart';
import 'package:abgui/src/ui/widgets/elapsed_ticker.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/search_field.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// What the dialog is about to do — and, for each, where it writes.
///
/// The prose lives on the enum rather than in the widget because these three sentences ARE the
/// safety feature. A view that composed them from the verb name would eventually say "adopt
/// attaches the configuration", which is the one thing adopt does not do.
enum MembershipAction {
  attach(
    title: 'Attach',
    symbol: 'link',
    scope: 'Apple Business + git',
    scopeSeverity: AbSeverity.drift,
    detail:
        'Adds the configuration to the blueprint in Apple Business, then rewrites the '
        'blueprint manifest to the full post-write membership. Devices in the blueprint start '
        'receiving the profile.',
    confirmLabel: 'Attach',
    resultTitle: 'Attached',
  ),
  detach(
    title: 'Detach',
    symbol: 'minus.circle',
    scope: 'Apple Business + git',
    scopeSeverity: AbSeverity.danger,
    detail:
        'Removes the configuration from the blueprint in Apple Business, then rewrites the '
        'manifest. Devices that get this profile from this blueprint stop receiving it.',
    confirmLabel: 'Detach',
    resultTitle: 'Detached',
  ),
  adopt(
    title: 'Adopt — mark as git-backed',
    symbol: 'checkmark.seal',
    scope: 'git only',
    scopeSeverity: AbSeverity.neutral,
    detail:
        'Records a configuration that is ALREADY attached in Apple Business into the blueprint '
        'manifest, so the reconcile stops proposing to detach it. Nothing in Apple Business '
        'changes. Use it after attaching in Apple\'s console.',
    confirmLabel: 'Record in git',
    resultTitle: 'Recorded in git',
  );

  const MembershipAction({
    required this.title,
    required this.symbol,
    required this.scope,
    required this.scopeSeverity,
    required this.detail,
    required this.confirmLabel,
    required this.resultTitle,
  });

  final String title;
  final String symbol;

  /// Where this verb writes, as the choice card's pill: 'Apple Business + git' or 'git only'.
  final String scope;
  final AbSeverity scopeSeverity;

  /// The consequence, in the operator's terms.
  final String detail;

  /// The word on the button that actually runs it.
  final String confirmLabel;

  /// The past tense, for the result panel.
  final String resultTitle;

  /// Whether this verb changes Apple Business. Only [adopt] does not — and that single boolean is
  /// what decides whether `--yes` is on the command line, what the confirm step warns about, and
  /// what an interrupted run may have left behind.
  bool get touchesTenant => this != MembershipAction.adopt;
}

/// Where the dialog is in the gate: choose, confirm, run, read the outcome.
enum _Stage { compose, confirm, running, done }

class MembershipDialog extends ConsumerStatefulWidget {
  const MembershipDialog({super.key, required this.blueprint});

  /// The blueprint being changed, as the list screen already holds it. The whole resource rather
  /// than an id, so the header can name it the way the table did.
  final Resource blueprint;

  static Future<void> show(
    BuildContext context, {
    required Resource blueprint,
  }) async {
    await showDialog<void>(
      context: context,
      // A membership write must not be dismissible by a stray click on the scrim while it is in
      // flight; the footer's Cancel is the way out, and it also stops the abctl child.
      barrierDismissible: false,
      builder: (BuildContext context) => MembershipDialog(blueprint: blueprint),
    );
  }

  @override
  ConsumerState<MembershipDialog> createState() => _MembershipDialogState();
}

class _MembershipDialogState extends ConsumerState<MembershipDialog> {
  static const InventoryPane _pane = InventoryPane.configurations;

  final TextEditingController _search = TextEditingController();

  _Stage _stage = _Stage.compose;
  MembershipAction _action = MembershipAction.attach;
  Resource? _config;
  String _filter = '';

  /// The run in flight: its start (for the live elapsed reading) and its kill switch.
  DateTime? _startedAt;
  CancelToken? _cancel;

  /// Exactly one of these is non-null once [_stage] is [_Stage.done].
  WriteOutcome? _outcome;
  Object? _failure;

  /// The verb the finished run actually used. Read instead of [_action] in the result panel: the
  /// user can start another change from the same dialog, and a result that re-read the live
  /// selection would relabel itself the moment they did.
  MembershipAction? _ranAction;

  @override
  void initState() {
    super.initState();
    // After the frame: every abctl run records into `commandLogProvider` synchronously before its
    // first await, and Riverpod refuses a provider modified during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(paneStatusProvider(_pane)).hasLoaded) return;
      unawaited(_loadConfigurations());
    });
  }

  @override
  void dispose() {
    // The dialog is gone; nothing is waiting for the answer. A membership verb can run for
    // minutes, and an orphaned abctl still holds a tenant connection.
    _cancel?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadConfigurations() =>
      ref.read(inventoryProvider.notifier).load(_pane);

  // -----------------------------------------------------------------------------------------
  // the write
  // -----------------------------------------------------------------------------------------

  /// The context-free argv for the current choice — the ONE place this dialog decides what to
  /// run, shared by the preview and by [_run] so the two cannot describe different commands.
  ///
  /// Null when the choice is incomplete, which is also what disables the buttons: there is no
  /// argv shape for "no configuration picked", and inventing one for the preview would advertise
  /// a command that cannot run.
  List<String>? get _argv {
    final Resource? config = _config;
    if (config == null || !_configIsWritable) return null;
    final String blueprint = _blueprintArg;
    if (blueprint.isEmpty) return null;
    switch (_action) {
      case MembershipAction.attach:
        return AbctlArgs.attachConfiguration(
          configId: config.id,
          blueprint: blueprint,
        );
      case MembershipAction.detach:
        return AbctlArgs.detachConfiguration(
          configId: config.id,
          blueprint: blueprint,
        );
      case MembershipAction.adopt:
        // The NAME, not the id: abctl resolves either, but the manifest records the canonical
        // name and an operator reading the command afterwards should see the thing they picked.
        // `config` is the only kind this dialog handles — the other five collections have no
        // attach/detach builder here, and a picker that offered them would be offering a verb
        // half of which does not exist.
        return AbctlArgs.adoptMember(
          kind: AbctlMemberKind.config,
          name: _configName,
          blueprint: blueprint,
        );
    }
  }

  /// The blueprint token every verb takes: the ID when Apple gave us one.
  ///
  /// `--blueprint` accepts a name or an id, and abctl tries a direct GET for an id before falling
  /// back to matching the name across the blueprint list. The id is preferred because two
  /// blueprints CAN share a name and that fallback takes the first match — a wrong-blueprint
  /// detach is silent, while an id abctl cannot resolve fails loudly with "not found". Between a
  /// quiet mistake and a noisy refusal on a live tenant, take the refusal. The NAME is what the
  /// prose says, because that is what the operator recognises.
  String get _blueprintArg =>
      widget.blueprint.id.isNotEmpty ? widget.blueprint.id : _blueprintName;

  String get _blueprintName =>
      widget.blueprint.attr('name') ?? widget.blueprint.id;

  String get _configName {
    final Resource? config = _config;
    if (config == null) return '';
    final String? name = config.attr('name');
    return name == null || name.isEmpty ? config.id : name;
  }

  /// Whether the selected row is a configuration these verbs can actually address.
  ///
  /// `abctl get configurations` lists EVERY type, but membership resolves the target from the
  /// CUSTOM_SETTING list only (`ab.Client.FetchCustomSettingsMetadata` filters on it), so a
  /// managed-payload row selected here would come back as `config "X" not found (by name or id)`
  /// — a message that reads like a bug when the row is visibly on screen. The rows stay listed,
  /// because hiding what the tenant contains is its own kind of lie; what changes is that the
  /// gate does not open, and the footer says why.
  ///
  /// An ABSENT type is treated as writable: it means abgui does not know, and abctl is the one
  /// entitled to refuse.
  bool get _configIsWritable {
    final String? type = _config?.attr('type');
    if (type == null || type.isEmpty) return true;
    return type.toUpperCase() == 'CUSTOM_SETTING';
  }

  Future<void> _run() async {
    // See `assign_dialog._run` for why this is "only from the confirm step" rather than "not
    // while running": the same one-frame window, and the same two consequences. A slow run means
    // the second activation overwrites `_cancel`, so the footer's Cancel reaches only the second
    // child while the first `detach` runs to completion against the blueprint unattended; a fast
    // one means a second tenant write from one approval.
    if (_stage != _Stage.confirm) return;
    final Resource? config = _config;
    if (config == null) return;
    final CancelToken cancel = CancelToken();
    final MembershipAction action = _action;
    setState(() {
      _stage = _Stage.running;
      _startedAt = DateTime.now();
      _cancel = cancel;
      _outcome = null;
      _failure = null;
      _ranAction = action;
    });

    final client = ref.read(abctlClientProvider);
    try {
      final WriteOutcome outcome = switch (action) {
        MembershipAction.attach => await client.attachConfiguration(
          configId: config.id,
          blueprint: _blueprintArg,
          cancel: cancel,
        ),
        MembershipAction.detach => await client.detachConfiguration(
          configId: config.id,
          blueprint: _blueprintArg,
          cancel: cancel,
        ),
        MembershipAction.adopt => await client.adoptMember(
          kind: AbctlMemberKind.config,
          name: _configName,
          blueprint: _blueprintArg,
          cancel: cancel,
        ),
      };
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _stage = _Stage.done;
        _cancel = null;
      });
    } catch (error) {
      if (!mounted) return;
      // The typed error is KEPT, not flattened to a string: a timeout, a cancellation and an
      // abctl refusal leave the tenant in three different states, and the result panel has to
      // say which — the whole point of the incident this dialog is built around.
      setState(() {
        _failure = error;
        _stage = _Stage.done;
        _cancel = null;
      });
    }
  }

  void _reset() {
    setState(() {
      _stage = _Stage.compose;
      _outcome = null;
      _failure = null;
      _ranAction = null;
      _startedAt = null;
    });
  }

  // -----------------------------------------------------------------------------------------
  // chrome
  // -----------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Size window = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: ab.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AbSpace.radius),
        side: BorderSide(color: ab.line),
      ),
      child: SizedBox(
        width: math.min(840, math.max(360, window.width - 80)),
        height: math.min(700, math.max(360, window.height - 80)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(ab),
            Divider(height: 1, color: ab.line),
            Expanded(child: _body(ab)),
            Divider(height: 1, color: ab.line),
            _footer(ab),
          ],
        ),
      ),
    );
  }

  Widget _header(AbColors ab) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AbSpace.md,
        AbSpace.sm,
        AbSpace.md,
        AbSpace.sm,
      ),
      decoration: BoxDecoration(color: ab.raised),
      child: Row(
        children: <Widget>[
          Icon(abIcon('square.stack.3d.up'), size: 15, color: ab.dim),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    'Membership — $_blueprintName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                ),
                // The id, because that is the token the command carries.
                MonoText(widget.blueprint.id, size: 11, color: ab.faint),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(AbColors ab) => switch (_stage) {
    _Stage.compose => _compose(ab),
    _Stage.confirm => _confirm(ab),
    _Stage.running => _running(ab),
    _Stage.done => _done(ab),
  };

  // -- compose -------------------------------------------------------------------------------

  Widget _compose(AbColors ab) {
    final String? workspace = ref.watch(workspaceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (workspace == null)
          NoticeBanner(
            icon: abIcon('folder.badge.questionmark'),
            tone: AbSeverity.danger,
            text: 'No workspace chosen',
            detail:
                'All three verbs write gitops/blueprints/ in the workspace, and abctl resolves '
                'that tree against the directory it runs in. Choose the workspace on the Diff '
                'screen first.',
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AbSpace.md,
              AbSpace.md,
              AbSpace.md,
              AbSpace.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('What to do', style: AbType.label(context)),
                const SizedBox(height: AbSpace.sm),
                for (final MembershipAction action
                    in MembershipAction.values) ...<Widget>[
                  AbChoiceCard(
                    title: action.title,
                    detail: action.detail,
                    icon: abIcon(action.symbol),
                    scope: action.scope,
                    scopeSeverity: action.scopeSeverity,
                    selected: _action == action,
                    onSelected: () => setState(() => _action = action),
                  ),
                  const SizedBox(height: AbSpace.sm),
                ],
              ],
            ),
          ),
        ),
        Divider(height: 1, color: ab.lineSoft),
        _configPicker(ab),
      ],
    );
  }

  /// The configuration list, as the app's own table.
  ///
  /// A table rather than a dropdown because a tenant can hold hundreds of configurations and the
  /// choice has to be searchable, sortable and readable — and because the table already knows how
  /// to say "still loading", "that read failed, here is Retry" and "this organization has none",
  /// three states a dropdown renders identically as an empty menu.
  Widget _configPicker(AbColors ab) {
    final List<Resource> rows = ref.watch(paneResourcesProvider(_pane));
    final PaneStatus status = ref.watch(paneStatusProvider(_pane));
    final AbDensity density = ref.watch(
      settingsProvider.select((Settings settings) => settings.density),
    );

    return SizedBox(
      height: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AbSpace.md,
              AbSpace.sm,
              AbSpace.md,
              AbSpace.sm,
            ),
            child: Row(
              children: <Widget>[
                Text('Configuration', style: AbType.label(context)),
                const Spacer(),
                InventorySearchField(
                  controller: _search,
                  width: 200,
                  onChanged: (String value) => setState(() => _filter = value),
                ),
              ],
            ),
          ),
          Expanded(
            child: AbTable<Resource>(
              rows: rows,
              columns: <AbColumn<Resource>>[
                AbColumn<Resource>(
                  header: 'Name',
                  value: (Resource row) => row.attr('name') ?? row.id,
                  flex: 3,
                  minWidth: 160,
                ),
                // The type is here because it decides whether a row can be a member at all:
                // membership resolves CUSTOM_SETTING configurations, and every other type is a
                // row you can see and cannot attach. Without the column, "why is Continue
                // greyed out?" has no answer on screen.
                AbColumn<Resource>(
                  header: 'Type',
                  value: (Resource row) => row.attr('type') ?? '—',
                  flex: 2,
                  minWidth: 120,
                ),
                AbColumn<Resource>(
                  header: 'ID',
                  value: (Resource row) => row.id,
                  type: AbColumnType.mono,
                  flex: 2,
                ),
              ],
              rowId: (Resource row) => row.id,
              filter: _filter,
              density: density,
              selectionMode: AbSelectionMode.single,
              onSelectionChanged: (List<Resource> selected) => setState(
                () => _config = selected.length == 1 ? selected.single : null,
              ),
              // "Never read" counts as loading: this dialog starts a read on open, and for the
              // one frame before it begins, an empty cache would render as "No configurations" —
              // a statement about the tenant made before anything was asked of it.
              isLoading:
                  status.isLoading ||
                  (!status.hasLoaded && status.error == null),
              error: status.error,
              emptyTitle: 'No configurations',
              emptyMessage:
                  'This organization has no CUSTOM_SETTING configurations in Apple Business, so '
                  'there is nothing to attach.',
              emptyIcon: abIcon('doc.text'),
              errorAction: ToolbarButton(
                icon: abIcon('arrow.clockwise'),
                label: 'Retry',
                tooltip: 'Read the configuration list again.',
                weight: AbToolbarWeight.titled,
                onPressed: () => unawaited(_loadConfigurations()),
              ),
              semanticsLabel: 'Configurations',
            ),
          ),
        ],
      ),
    );
  }

  // -- confirm -------------------------------------------------------------------------------

  Widget _confirm(AbColors ab) {
    final List<String>? argv = _argv;
    final String? workspace = ref.watch(workspaceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AbSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('About to run', style: AbType.label(context)),
                const SizedBox(height: AbSpace.sm),
                AbNote(text: _confirmSentence()),
                const SizedBox(height: AbSpace.md),
                _kv(ab, 'Configuration', _configName, mono: false),
                _kv(ab, 'Configuration id', _config?.id ?? '—'),
                _kv(ab, 'Blueprint', _blueprintName, mono: false),
                _kv(ab, 'Blueprint id', widget.blueprint.id),
                if (workspace != null) _kv(ab, 'Workspace', workspace),
              ],
            ),
          ),
        ),
        if (argv != null)
          CommandPreview(
            base: argv,
            // The workspace, because all three verbs resolve gitops/ against the directory they
            // run in — the copied form has to carry the same `cd` the app applies.
            cwd: workspace,
            caption: _action.touchesTenant
                ? '`--yes` is on the line because THIS confirmation is the gate — abctl will not '
                      'ask again.'
                : 'No `--yes`: adopt writes local files only, so there is nothing in the tenant '
                      'to gate.',
          ),
      ],
    );
  }

  String _confirmSentence() => switch (_action) {
    MembershipAction.attach =>
      'abctl will attach $_configName to blueprint $_blueprintName in Apple Business, then '
          'rewrite that blueprint\'s manifest to the full post-write membership. Every device in '
          'the blueprint starts receiving this profile.',
    MembershipAction.detach =>
      'abctl will detach $_configName from blueprint $_blueprintName in Apple Business, then '
          'rewrite that blueprint\'s manifest. Devices that receive this profile through '
          '$_blueprintName stop receiving it. Apple keeps no undo for this — re-attaching is the '
          'only way back.',
    MembershipAction.adopt =>
      'abctl will record $_configName in $_blueprintName\'s manifest under gitops/blueprints/, so '
          'the reconcile stops proposing to detach it. Apple Business is not touched. If the '
          'configuration is not actually attached there, abctl refuses — adopt only ever records '
          'what is already live.',
  };

  // -- running -------------------------------------------------------------------------------

  /// The one screen the incident report is about.
  ///
  /// `adopt` against a real tenant is four round trips (resolve the blueprint, index every
  /// configuration for the name↔id map, read the blueprint's current members, write the manifest).
  /// On the plain 60s read budget it died mid-flight and left the manifest unwritten, and the only
  /// thing the GUI said was "abctl ran for 60s" — a timeout that reads exactly like a broken
  /// feature. So: a live elapsed reading (so it is visibly alive), the steps the verb performs (so
  /// a long wait is explicable), and the budget as a number (so "it hung" and "it was stopped" are
  /// different, nameable outcomes).
  Widget _running(AbColors ab) {
    final DateTime started = _startedAt ?? DateTime.now();
    final MembershipAction action = _ranAction ?? _action;
    return Padding(
      padding: const EdgeInsets.all(AbSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: ab.accent,
                ),
              ),
              const SizedBox(width: AbSpace.sm),
              Text(
                'Running abctl ${action.name}…',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ab.text,
                ),
              ),
              const SizedBox(width: AbSpace.sm),
              ElapsedTicker(startedAt: started),
            ],
          ),
          const SizedBox(height: AbSpace.md),
          Text(
            'This verb is several calls to Apple, not one:',
            style: TextStyle(fontSize: 12, color: ab.dim),
          ),
          const SizedBox(height: AbSpace.xs),
          // Not a progress tracker: abctl reports no phase on stdout, so ticking these off would
          // be abgui inventing a position it cannot know. They are here to make a long wait
          // explicable, which is a different job from claiming to know where it is.
          for (final String step in <String>[
            'resolve the blueprint',
            'index every configuration for the name ↔ id map',
            'read the blueprint\'s current members',
            action == MembershipAction.adopt
                ? 'write the manifest'
                : 'write the membership, then rewrite the manifest',
          ])
            Padding(
              padding: const EdgeInsets.only(left: AbSpace.sm, top: 2),
              child: Text(
                '· $step',
                style: TextStyle(fontSize: 12, color: ab.faint),
              ),
            ),
          const SizedBox(height: AbSpace.md),
          Text(
            'A tenant with many configurations makes the index step slow. abgui stops the command '
            'after ${AbctlTimeouts.membership.inSeconds}s; Cancel stops it now.',
            style: TextStyle(fontSize: 11.5, height: 1.4, color: ab.faint),
          ),
        ],
      ),
    );
  }

  // -- done ----------------------------------------------------------------------------------

  Widget _done(AbColors ab) {
    final WriteOutcome? outcome = _outcome;
    if (outcome != null) return _success(ab, outcome);
    return _failed(ab);
  }

  Widget _success(AbColors ab, WriteOutcome outcome) {
    final MembershipAction action = _ranAction ?? _action;
    final String? treeWarning = outcome.treeWarning;
    // abctl's own names, not the ones this dialog sent: it resolves the canonical spelling, and
    // the manifest is written under that.
    final String name = outcome.name.isEmpty ? _configName : outcome.name;
    final String blueprint = outcome.blueprint ?? _blueprintName;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AbSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(abIcon('checkmark.circle'), size: 16, color: ab.ok),
              const SizedBox(width: AbSpace.sm),
              Text(
                action.resultTitle,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: ab.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: AbSpace.sm),
          AbNote(
            text: action.touchesTenant
                ? '$name ${action == MembershipAction.attach ? 'is now attached to' : 'is no longer attached to'} '
                      '$blueprint in Apple Business.'
                : '$name is now declared on $blueprint in gitops/blueprints/. The reconcile will '
                      'stop proposing to detach it.',
          ),
          const SizedBox(height: AbSpace.md),
          _kv(ab, 'Configuration', name, mono: false),
          if (outcome.id != null) _kv(ab, 'Configuration id', outcome.id!),
          _kv(ab, 'Blueprint', blueprint, mono: false),
          const SizedBox(height: AbSpace.md),
          Text('The git half', style: AbType.label(context)),
          const SizedBox(height: AbSpace.xs),
          // The manifest result, stated either way. abctl exits 0 for a tenant write whose local
          // half failed, so silence here would report a half-done write as a clean one — the exact
          // shape of the bug where a GUI attach never reached the manifest and came back as a
          // drift row nobody could clear.
          if (treeWarning != null) ...<Widget>[
            NoticeBanner(
              icon: abIcon('exclamationmark.triangle'),
              tone: AbSeverity.danger,
              text: 'Written to Apple, not to git',
              detail: treeWarning,
            ),
            const SizedBox(height: AbSpace.sm),
            _recovery(name, blueprint),
          ] else if (outcome.treeUpdated) ...<Widget>[
            AbNote(
              text:
                  'gitops/blueprints/ now records this. Commit gitops/ to keep it — an uncommitted '
                  'manifest is only true on this machine.',
              tone: AbSeverity.ok,
            ),
          ] else ...<Widget>[
            AbNote(
              text:
                  'abctl did not report a manifest write. Check gitops/blueprints/ with `git status` '
                  'before assuming git agrees with Apple Business.',
              tone: AbSeverity.drift,
            ),
          ],
          const SizedBox(height: AbSpace.md),
          Text(
            'The plan on the Diff screen was computed before this change — refresh it there to see '
            'the tenant and git as they are now.',
            style: TextStyle(fontSize: 11.5, height: 1.4, color: ab.faint),
          ),
        ],
      ),
    );
  }

  /// The command abctl's own stderr recommends when the tenant write landed and the manifest did
  /// not — `adopt config <name> --blueprint <bp>`, run from the workspace.
  ///
  /// Through [CommandPreview] because the quoting and the `cd` are the whole point of a command
  /// offered for copying: a configuration called `Corp WiFi.mobileconfig` pasted unquoted is two
  /// arguments, and an adopt run outside the workspace writes the manifest that is already
  /// missing into a second wrong tree. The label is overridden so it cannot read as something
  /// abgui ran.
  Widget _recovery(String name, String blueprint) => CommandPreview(
    base: AbctlArgs.adoptMember(
      kind: AbctlMemberKind.config,
      name: name,
      blueprint: blueprint,
    ),
    cwd: ref.watch(workspaceProvider),
    label: 'To record it in git',
    caption:
        'abgui has NOT run this. Copy it, or choose Adopt above — either way it writes the '
        'manifest without touching Apple Business again.',
  );

  Widget _failed(AbColors ab) {
    final Object error = _failure ?? 'abctl reported no result.';
    final MembershipAction action = _ranAction ?? _action;
    final bool cancelled = error is AbctlCancelled;
    final bool timedOut = error is AbctlTimedOut;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AbSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                abIcon(
                  cancelled
                      ? 'slash.circle'
                      : (timedOut
                            ? 'clock.badge.exclamationmark'
                            : 'exclamationmark.triangle'),
                ),
                size: 16,
                color: cancelled ? ab.dim : ab.danger,
              ),
              const SizedBox(width: AbSpace.sm),
              Text(
                cancelled
                    ? 'Stopped'
                    : (timedOut
                          ? '${action.title.split(' ').first} timed out'
                          : '${action.title.split(' ').first} failed'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: ab.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: AbSpace.sm),
          // abctl's own words. Its stderr is written for a human and names the thing that went
          // wrong ("not attached to blueprint …", "has no manifest … run abctl seed"); replacing
          // it with a paraphrase throws away the only actionable half.
          Container(
            width: double.infinity,
            color: ab.raised,
            padding: const EdgeInsets.all(AbSpace.sm),
            child: SelectableText(
              loadErrorText(error),
              style: AbType.mono(context, size: 11, color: ab.text),
            ),
          ),
          const SizedBox(height: AbSpace.md),
          Text('What this means', style: AbType.label(context)),
          const SizedBox(height: AbSpace.xs),
          AbNote(
            text: _aftermath(
              action,
              cancelled: cancelled,
              interrupted: timedOut,
            ),
            tone: AbSeverity.drift,
          ),
        ],
      ),
    );
  }

  /// What is true about the tenant and the tree after a run that did not finish cleanly.
  ///
  /// Three different answers, because they are three different states. A killed process says
  /// nothing about whether the HTTP request it had already sent arrived — so an interrupted
  /// attach/detach must never be reported as "nothing happened", and an interrupted adopt must
  /// never be reported as "the tenant may have changed", because adopt cannot change it.
  String _aftermath(
    MembershipAction action, {
    required bool cancelled,
    required bool interrupted,
  }) {
    if (!cancelled && !interrupted) {
      return action.touchesTenant
          ? 'abctl printed no outcome document, so it did not complete the write. A membership '
                'verb resolves the blueprint and the configuration BEFORE it writes — a refusal '
                'at that stage never reached Apple Business — and a failure of the write itself '
                'means Apple rejected it. The message above is abctl\'s own account of which.'
          : 'Nothing was written. adopt only ever writes gitops/blueprints/, so Apple Business '
                'is not affected by this failure — the manifest simply still does not record '
                'this member.';
    }
    final String verb = cancelled
        ? 'abgui stopped abctl'
        : 'abgui timed out and killed abctl';
    return action.touchesTenant
        ? '$verb mid-run. If the membership request had already been sent, Apple Business kept '
              'it — but the manifest rewrite that follows it may not have happened. Check the '
              'blueprint\'s members and `git status` in the workspace before retrying.'
        : '$verb mid-run. Apple Business cannot have changed — adopt never writes the tenant. The '
              'manifest may or may not have been written; check `git status` in the workspace. '
              'Re-running adopt is safe: recording a member that is already declared changes '
              'nothing.';
  }

  // -- footer --------------------------------------------------------------------------------

  Widget _footer(AbColors ab) {
    final bool hasWorkspace = ref.watch(workspaceProvider) != null;
    final bool ready = _argv != null && hasWorkspace;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbSpace.md,
        AbSpace.sm,
        AbSpace.md,
        AbSpace.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: _footerNote(ab, ready: ready)),
          ...switch (_stage) {
            _Stage.compose => <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: AbSpace.sm),
              FilledButton(
                onPressed: ready
                    ? () => setState(() => _stage = _Stage.confirm)
                    : null,
                child: const Text('Continue'),
              ),
            ],
            _Stage.confirm => <Widget>[
              TextButton(
                onPressed: () => setState(() => _stage = _Stage.compose),
                child: const Text('Back'),
              ),
              const SizedBox(width: AbSpace.sm),
              FilledButton(
                // The destructive verb gets the destructive colour. Everything else about the two
                // buttons is identical, so the colour is the only thing carrying "this removes
                // something" — which is why the label says Detach rather than OK.
                style: _action == MembershipAction.detach
                    ? FilledButton.styleFrom(
                        backgroundColor: ab.danger,
                        foregroundColor: ab.surface,
                      )
                    : null,
                onPressed: ready ? () => unawaited(_run()) : null,
                child: Text(_action.confirmLabel),
              ),
            ],
            _Stage.running => <Widget>[
              TextButton(
                onPressed: () => _cancel?.cancel(),
                child: const Text('Cancel'),
              ),
            ],
            _Stage.done => <Widget>[
              TextButton(
                onPressed: _reset,
                child: const Text('Make another change'),
              ),
              const SizedBox(width: AbSpace.sm),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          },
        ],
      ),
    );
  }

  Widget _footerNote(AbColors ab, {required bool ready}) {
    final String text = switch (_stage) {
      _Stage.compose when !ready && ref.watch(workspaceProvider) == null =>
        'Choose a workspace before changing membership.',
      _Stage.compose when _config != null && !_configIsWritable =>
        'Blueprint membership covers CUSTOM_SETTING configurations; '
            '${_config!.attr('type')} is managed by Apple Business itself.',
      _Stage.compose when !ready => 'Pick a configuration to continue.',
      _Stage.compose => '${_action.title} · $_configName',
      _Stage.confirm =>
        _action.touchesTenant
            ? 'This is the confirmation. The next click reaches Apple Business.'
            : 'This writes local files only.',
      _Stage.running =>
        'Cancel stops abctl; it does not undo what it already sent.',
      _Stage.done => '',
    };
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11.5, color: ab.faint),
    );
  }

  // -- small shared pieces ---------------------------------------------------------------------

  Widget _kv(AbColors ab, String label, String value, {bool mono = true}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: AbSpace.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 130,
              child: Text(label, style: AbType.label(context)),
            ),
            Expanded(
              child: mono
                  ? MonoText(value, size: 11.5, color: ab.dim)
                  : Text(
                      value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: ab.text),
                    ),
            ),
          ],
        ),
      );
}
