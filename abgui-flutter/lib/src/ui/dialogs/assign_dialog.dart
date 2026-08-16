// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Device assignment: move the devices selected on the Devices screen between MDM servers.
///
/// **Apple processes this asynchronously, and everything about this dialog follows from that.**
/// `assign` / `unassign` do not move a device; they submit an `orgDeviceActivity` and return its
/// id. A success here means ACCEPTED, not applied — so the result panel says "accepted", offers
/// Check status (`abctl status activity <id>`), and points at the result log Apple publishes when
/// it has finished, which is the only place a PER-DEVICE verdict exists.
///
/// **What a failure means, precisely.** abctl resolves every serial to an org-device id BEFORE it
/// submits anything (`internal/cli/manage.go`: `resolveDeviceIDs` runs ahead of `AssignDevices`),
/// and one unknown or ambiguous serial fails the whole command. So a failed run submitted nothing
/// at all — no device moved, not even the ones that resolved. That is a materially different
/// outcome from "some of it went through", and the per-device table below states which one it was
/// instead of leaving the operator to guess.
///
/// **No workspace, deliberately.** Assignment is a pure tenant call: it reads nothing from
/// `gitops/` and writes nothing to it, so the preview carries no `cd` — printing one would imply a
/// workspace matters to a verb that never looks at one.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/inspect.dart';
import 'package:abgui/src/models/resource.dart';
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
import 'package:abgui/src/ui/widgets/copy_button.dart';
import 'package:abgui/src/ui/widgets/elapsed_ticker.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// What became of ONE device in the list the operator selected.
///
/// Every state here is something abgui can actually know. There is deliberately no "assigned":
/// Apple has not finished when the command returns, so claiming a device is assigned would be
/// abgui asserting an outcome only the activity's result log can report.
enum _DeviceOutcome {
  /// Not sent yet.
  queued('Queued', AbSeverity.neutral),

  /// Part of the accepted activity. Apple has the request; it has not necessarily applied it.
  submitted('Submitted', AbSeverity.ok),

  /// The activity was accepted for FEWER devices than were selected. Which ones were dropped is
  /// not in the response, so every row wears this rather than three of them wearing a guess.
  unconfirmed('Unconfirmed', AbSeverity.drift),

  /// abctl's failure names this device — an unknown serial, or one shared by two devices.
  rejected('Rejected', AbSeverity.danger),

  /// The run was stopped — by the operator or by abgui's watchdog — before abctl answered.
  ///
  /// **Distinct from [notSubmitted], and the distinction is the whole reason this value exists.**
  /// abctl resolves every serial before it POSTs, so an abctl-REPORTED refusal really does mean
  /// nothing was sent. A kill says nothing at all: it can land after the POST, in which case
  /// Apple has the activity and will process it. Painting "Not submitted" down the column in that
  /// case is a positive claim about a live tenant that abgui is not in a position to make, and
  /// the operator acts on it by re-submitting — creating a duplicate activity.
  unknown('Unknown', AbSeverity.drift),

  /// The command failed before submission, so this device was never sent. Resolution happens
  /// ahead of the write, which is why this is a certainty and not a hope — and why it is only
  /// used for a failure abctl itself reported. See [unknown].
  notSubmitted('Not submitted', AbSeverity.neutral);

  const _DeviceOutcome(this.label, this.severity);

  final String label;
  final AbSeverity severity;
}

enum _Stage { compose, confirm, running, done }

class AssignDialog extends ConsumerStatefulWidget {
  const AssignDialog({super.key, required this.devices});

  /// The rows selected in the Devices table, in table order. Whole resources rather than serials,
  /// so the list on screen can show the model beside the serial — the operator picked rows, and
  /// a confirmation that reduces them to a column of opaque strings is harder to check.
  final List<Resource> devices;

  /// Returns true when an activity was accepted, so the caller can re-read the device list.
  static Future<bool> show(
    BuildContext context, {
    required List<Resource> devices,
  }) async {
    final bool? submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AssignDialog(devices: devices),
    );
    return submitted ?? false;
  }

  @override
  ConsumerState<AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends ConsumerState<AssignDialog> {
  static const InventoryPane _pane = InventoryPane.mdmServers;

  _Stage _stage = _Stage.compose;
  AbctlAssignment _action = AbctlAssignment.assign;
  Resource? _server;

  DateTime? _startedAt;
  CancelToken? _cancel;

  ActivityOutcome? _outcome;
  Object? _failure;
  AbctlAssignment? _ranAction;

  /// The polled activity, and its own busy/error state. Separate from the write's: a failed poll
  /// says nothing about the write that succeeded, and rendering it in the write's error slot
  /// would turn "we could not read the status" into "the assignment failed".
  Resource? _activity;
  bool _polling = false;
  Object? _pollFailure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(paneStatusProvider(_pane)).hasLoaded) {
        _selectDefaultServer();
        return;
      }
      unawaited(_loadServers());
    });
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _loadServers() async {
    await ref.read(inventoryProvider.notifier).load(_pane);
    if (!mounted) return;
    _selectDefaultServer();
  }

  /// Preselect nothing when there is more than one server. The Swift sheet defaulted to the first
  /// row, which on a tenant with several MDM servers puts a live, correct-looking command on
  /// screen naming a server the operator never chose.
  void _selectDefaultServer() {
    final List<Resource> servers = ref.read(paneResourcesProvider(_pane));
    if (servers.length == 1 && _server == null) {
      setState(() => _server = servers.single);
    }
  }

  // -----------------------------------------------------------------------------------------
  // the write
  // -----------------------------------------------------------------------------------------

  /// The serials, positionally, in the order the table had them.
  ///
  /// `serialNumber ?? id` because abctl resolves either (`deviceIDsFromList` matches an exact id
  /// first, then a serial): a device Apple returned without a serial is still addressable, and
  /// dropping it from the list silently would assign fewer devices than the operator selected.
  ///
  /// Computed once. The outcome column asks for its length per row per build, and the selection
  /// cannot change while this dialog is open — the rows came in with the widget.
  late final List<String> _serials = <String>[
    for (final Resource device in widget.devices) _serialOf(device),
  ];

  static String _serialOf(Resource device) {
    final String? serial = device.attr('serialNumber');
    return serial == null || serial.isEmpty ? device.id : serial;
  }

  /// The context-free argv, or null when no server is chosen. One builder for both verbs, so
  /// switching Assign/Unassign cannot leave the preview describing the other one.
  List<String>? get _argv {
    final Resource? server = _server;
    if (server == null || _serials.isEmpty) return null;
    return AbctlArgs.assignment(
      action: _action,
      server: _serverArg(server),
      serials: _serials,
    );
  }

  /// The token `--server` gets: the id when Apple gave us one. `ResolveMDMServer` takes a name or
  /// an id, and an id cannot be ambiguous between two servers with similar names.
  static String _serverArg(Resource server) =>
      server.id.isNotEmpty ? server.id : (server.attr('serverName') ?? '');

  String get _serverName =>
      _server?.attr('serverName') ?? _server?.id ?? '(none)';

  Future<void> _run() async {
    // The guard its siblings have and these two did not (`config_editor_dialog._save` opens with
    // `if (_writing) return;`, `_delete` with `if (_deleting) return;`).
    //
    // **Stated as "only from the confirm step", not as "not while running", because both of the
    // two ways a repeat happens have to be closed.** The button only exists during
    // [_Stage.confirm], but that is a property of a rebuilt FRAME: two activations with no frame
    // between them — a double-click, an accessibility `activate`, a synthesized tap — both reach
    // the closure the last build captured. A slow run means the second one lands while the first
    // is still in flight (`_cancel` is overwritten, so the footer's Cancel reaches only the
    // second child and the first activity runs on against the tenant untracked); a fast one
    // means it lands after the first has already finished, which submits a SECOND activity from
    // one approval. Only `_stage == _Stage.confirm` refuses both.
    if (_stage != _Stage.confirm) return;
    final Resource? server = _server;
    if (server == null) return;
    final CancelToken cancel = CancelToken();
    final AbctlAssignment action = _action;
    setState(() {
      _stage = _Stage.running;
      _startedAt = DateTime.now();
      _cancel = cancel;
      _outcome = null;
      _failure = null;
      _activity = null;
      _pollFailure = null;
      _ranAction = action;
    });

    try {
      final ActivityOutcome outcome = await ref
          .read(abctlClientProvider)
          .assignDevices(
            action: action,
            server: _serverArg(server),
            serials: _serials,
            cancel: cancel,
          );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _stage = _Stage.done;
        _cancel = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = error;
        _stage = _Stage.done;
        _cancel = null;
      });
    }
  }

  /// Poll the accepted activity. This is a READ, so it is not gated and can be repeated.
  Future<void> _poll() async {
    final ActivityOutcome? outcome = _outcome;
    if (outcome == null || outcome.activityID.isEmpty) return;
    setState(() {
      _polling = true;
      _pollFailure = null;
    });
    try {
      final Resource activity = await ref
          .read(abctlClientProvider)
          .activityStatus(outcome.activityID);
      if (!mounted) return;
      setState(() {
        _activity = activity;
        _polling = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _pollFailure = error;
        _polling = false;
      });
    }
  }

  /// What happened to one device, from the facts in hand and nothing else.
  ///
  /// The failure branch matches the QUOTED serial in abctl's own message, because that is where
  /// the naming happens and how it is spelled: `device %q not found (by serial number or id)`,
  /// `device serial %q is ambiguous`. Quoted rather than a bare substring on purpose — `C02AAA`
  /// is a substring of `C02AAAX`, and marking the wrong device Rejected is a worse answer than
  /// marking both Not submitted, which is what an unrecognised message shape falls back to.
  /// (Neither is a guess about the tenant: nothing was submitted either way.)
  _DeviceOutcome _outcomeFor(String serial) {
    final ActivityOutcome? outcome = _outcome;
    final Object? failure = _failure;
    if (_stage != _Stage.done) return _DeviceOutcome.queued;
    if (outcome != null) {
      return outcome.devices >= _serials.length
          ? _DeviceOutcome.submitted
          : _DeviceOutcome.unconfirmed;
    }
    // Ahead of both branches below, because both of them are reasoning about a message abctl
    // wrote to explain itself, and an interrupted run wrote no such message. See [_interrupted]
    // and [_DeviceOutcome.unknown].
    if (_interrupted) return _DeviceOutcome.unknown;
    if (failure != null &&
        loadErrorText(
          failure,
        ).toLowerCase().contains('"${serial.toLowerCase()}"')) {
      return _DeviceOutcome.rejected;
    }
    return _DeviceOutcome.notSubmitted;
  }

  /// True when the run was stopped rather than answered: a cancel, or abgui's own watchdog.
  ///
  /// **Two claims on this screen were derived from a failure's TEXT, and for these two errors the
  /// text is not a failure report.** `AbctlTimedOut.message` appends abctl's whole stderr tail
  /// ("Last output from abctl: …"), which during an assignment is its progress narration — and
  /// abctl narrates serials in quotes while it resolves them. So the substring match in
  /// [_outcomeFor], written against abctl's refusal wording (`device %q not found`), would read a
  /// progress line and mark that device "Rejected": an assertion that Apple refused a specific
  /// device, invented out of a log line. The comment above that branch reasons carefully about
  /// `C02AAA` versus `C02AAAX` and then assumes the text is a refusal; this is the assumption it
  /// was missing.
  bool get _interrupted =>
      _failure is AbctlCancelled || _failure is AbctlTimedOut;

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
        width: math.min(860, math.max(360, window.width - 80)),
        height: math.min(720, math.max(360, window.height - 80)),
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
      color: ab.raised,
      child: Row(
        children: <Widget>[
          Icon(abIcon('laptopcomputer'), size: 15, color: ab.dim),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'Device assignment',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ab.text,
                ),
              ),
            ),
          ),
          Text(
            '${widget.devices.length} selected',
            style: TextStyle(fontSize: 11.5, color: ab.faint),
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

  /// Fixed-height panes inside one scroll view, rather than flex shares of whatever is left.
  ///
  /// A table needs a floor: squeezed below about 160px its empty and error states — the very
  /// states an operator needs to READ ("no MDM servers", "that read failed, here is Retry") — no
  /// longer fit, and a pane that cannot render its own failure is worse than one that scrolls. So
  /// each section claims a height it can actually use and a short window scrolls the dialog.
  Widget _compose(AbColors ab) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
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
                AbChoiceCard(
                  title: 'Assign',
                  detail:
                      'Hands these devices to the chosen MDM server. A device already assigned '
                      'elsewhere moves — Apple does not ask twice.',
                  icon: abIcon('arrow.left.arrow.right'),
                  scope: 'Apple Business',
                  scopeSeverity: AbSeverity.drift,
                  selected: _action == AbctlAssignment.assign,
                  onSelected: () =>
                      setState(() => _action = AbctlAssignment.assign),
                ),
                const SizedBox(height: AbSpace.sm),
                AbChoiceCard(
                  title: 'Unassign',
                  detail:
                      'Removes these devices from the chosen MDM server. They stay in the '
                      'organization but enroll nowhere until they are assigned again.',
                  icon: abIcon('minus.circle'),
                  scope: 'Apple Business',
                  scopeSeverity: AbSeverity.danger,
                  selected: _action == AbctlAssignment.unassign,
                  onSelected: () =>
                      setState(() => _action = AbctlAssignment.unassign),
                ),
              ],
            ),
          ),
          SizedBox(height: _paneHeight, child: _serverPicker(ab)),
          Divider(height: 1, color: ab.lineSoft),
          SizedBox(height: _paneHeight, child: _deviceList(ab)),
        ],
      ),
    );
  }

  /// The floor a table pane gets in this dialog: its own header, a few rows, and enough room for
  /// the empty/error state to render without being clipped.
  static const double _paneHeight = 250;

  /// The MDM servers, from the shared cache but with THIS pane's own loading and error state.
  ///
  /// A swallowed failure here would render as "No MDM servers found" on the picker that gates a
  /// device write — the operator would read a broken read as an empty tenant. The pane's status is
  /// what keeps those two apart, and the table renders each of them differently.
  Widget _serverPicker(AbColors ab) {
    final List<Resource> rows = ref.watch(paneResourcesProvider(_pane));
    final PaneStatus status = ref.watch(paneStatusProvider(_pane));
    final AbDensity density = ref.watch(
      settingsProvider.select((Settings settings) => settings.density),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbSpace.md,
            AbSpace.sm,
            AbSpace.md,
            AbSpace.xs,
          ),
          child: Text('MDM server', style: AbType.label(context)),
        ),
        Expanded(
          child: AbTable<Resource>(
            rows: rows,
            columns: <AbColumn<Resource>>[
              AbColumn<Resource>(
                header: 'Server',
                value: (Resource row) => row.attr('serverName') ?? row.id,
                flex: 3,
                minWidth: 160,
              ),
              AbColumn<Resource>(
                header: 'Type',
                value: (Resource row) => row.attr('serverType') ?? '—',
                flex: 1,
              ),
              AbColumn<Resource>(
                header: 'ID',
                value: (Resource row) => row.id,
                type: AbColumnType.mono,
                flex: 2,
              ),
            ],
            rowId: (Resource row) => row.id,
            density: density,
            selectionMode: AbSelectionMode.single,
            onSelectionChanged: (List<Resource> selected) => setState(
              () => _server = selected.length == 1 ? selected.single : null,
            ),
            // "Never read" counts as loading, because this dialog always starts a read on open:
            // for the one frame before it begins, an empty cache would otherwise render as "No
            // MDM servers" — a claim about the tenant made before anyone asked it anything, on
            // the picker that gates a device write.
            isLoading:
                status.isLoading || (!status.hasLoaded && status.error == null),
            error: status.error,
            emptyTitle: 'No MDM servers',
            emptyMessage:
                'Apple Business lists no MDM servers for this organization, so there is nothing '
                'to assign devices to.',
            emptyIcon: abIcon('server.rack'),
            errorAction: ToolbarButton(
              icon: abIcon('arrow.clockwise'),
              label: 'Retry',
              tooltip: 'Read the MDM server list again.',
              weight: AbToolbarWeight.titled,
              onPressed: () => unawaited(_loadServers()),
            ),
            semanticsLabel: 'MDM servers',
          ),
        ),
      ],
    );
  }

  /// The devices, with the outcome column that carries the per-item result.
  ///
  /// The same table before and after the write, on purpose: the row an operator checked in the
  /// confirmation is the row they read the verdict off, in the same order, so there is no
  /// re-matching to do by eye.
  Widget _deviceList(AbColors ab) {
    final AbDensity density = ref.watch(
      settingsProvider.select((Settings settings) => settings.density),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbSpace.md,
            AbSpace.sm,
            AbSpace.md,
            AbSpace.xs,
          ),
          child: Row(
            children: <Widget>[
              Text('Devices', style: AbType.label(context)),
              const Spacer(),
              CopyButton(
                text: () => _serials.join('\n'),
                label: 'Copy serials',
                tooltip:
                    'Copy the exact serial list this command sends, one per line.',
              ),
            ],
          ),
        ),
        Expanded(
          child: AbTable<Resource>(
            rows: widget.devices,
            columns: <AbColumn<Resource>>[
              AbColumn<Resource>(
                header: 'Serial',
                value: _serialOf,
                type: AbColumnType.mono,
                width: 170,
              ),
              AbColumn<Resource>(
                header: 'Model',
                value: (Resource row) => row.attr('deviceModel') ?? '—',
                flex: 2,
              ),
              AbColumn<Resource>(
                header: 'Outcome',
                value: (Resource row) => _outcomeFor(_serialOf(row)).label,
                type: AbColumnType.badge,
                width: 150,
                severity: (Resource row) =>
                    _outcomeFor(_serialOf(row)).severity,
              ),
            ],
            rowId: (Resource row) => row.id.isEmpty ? _serialOf(row) : row.id,
            density: density,
            // Nothing to select: the selection was made on the Devices screen, and a second one
            // here would be a second answer to a question already asked.
            selectionMode: AbSelectionMode.none,
            emptyTitle: 'No devices',
            emptyMessage: 'Select devices on the Devices screen first.',
            emptyIcon: abIcon('laptopcomputer'),
            semanticsLabel: 'Selected devices',
          ),
        ),
      ],
    );
  }

  // -- confirm -------------------------------------------------------------------------------

  Widget _confirm(AbColors ab) {
    final List<String>? argv = _argv;
    final String preposition = _action == AbctlAssignment.assign
        ? 'to'
        : 'from';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(AbSpace.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('About to run', style: AbType.label(context)),
                      const SizedBox(height: AbSpace.sm),
                      AbNote(
                        text:
                            'abctl will ${_action.verb} ${widget.devices.length} device(s) '
                            '$preposition MDM server $_serverName. Apple accepts this as an ACTIVITY '
                            'and processes it afterwards, so the result below will say accepted, not '
                            'finished.',
                      ),
                    ],
                  ),
                ),
                // The same list, at the same height, as the one just approved on the compose
                // step — a confirmation that reflows its evidence is a confirmation of something
                // slightly different from what was read.
                SizedBox(height: _paneHeight, child: _deviceList(ab)),
              ],
            ),
          ),
        ),
        if (argv != null)
          CommandPreview(
            base: argv,
            // No cwd: assignment resolves nothing from gitops/, and a `cd` in the copied form
            // would imply a workspace matters here.
            caption:
                '`--yes` is on the line because THIS confirmation is the gate. The serials are '
                'positional, exactly as shown.',
          ),
      ],
    );
  }

  // -- running -------------------------------------------------------------------------------

  Widget _running(AbColors ab) {
    final DateTime started = _startedAt ?? DateTime.now();
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
                'Running abctl ${(_ranAction ?? _action).verb}…',
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
            'abctl resolves the MDM server, then reads the whole device inventory once to turn '
            'these serials into ids, and only then submits the activity. On a large tenant the '
            'inventory read is the slow part.',
            style: TextStyle(fontSize: 12, height: 1.4, color: ab.dim),
          ),
          const SizedBox(height: AbSpace.sm),
          Text(
            'Cancel stops abctl. If the activity had already been submitted, Apple keeps it — '
            'Check status on the next screen is how you find out.',
            style: TextStyle(fontSize: 11.5, height: 1.4, color: ab.faint),
          ),
        ],
      ),
    );
  }

  // -- done ----------------------------------------------------------------------------------

  Widget _done(AbColors ab) {
    final ActivityOutcome? outcome = _outcome;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AbSpace.md),
            child: outcome == null
                ? _failedPanel(ab)
                : _acceptedPanel(ab, outcome),
          ),
        ),
        Divider(height: 1, color: ab.lineSoft),
        // The verdict per device stays on screen beside the summary: "accepted" is a number, and
        // the number is only checkable against the rows it was accepted for.
        SizedBox(height: _paneHeight, child: _deviceList(ab)),
      ],
    );
  }

  Widget _acceptedPanel(AbColors ab, ActivityOutcome outcome) {
    final bool partial = outcome.devices < _serials.length;
    final Resource? activity = _activity;
    final Object? pollFailure = _pollFailure;
    final String? downloadUrl = activity?.attr('downloadUrl');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(abIcon('checkmark.circle'), size: 16, color: ab.ok),
            const SizedBox(width: AbSpace.sm),
            Text(
              'Accepted',
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
          text:
              'Apple accepted ${outcome.action.isEmpty ? (_ranAction ?? _action).verb : outcome.action} '
              'activity ${outcome.activityID} for ${outcome.devices} device(s) on '
              '${outcome.server.isEmpty ? _serverName : outcome.server}. Accepted is not finished: '
              'Apple applies the activity afterwards, and may still reject individual devices while '
              'doing so.',
        ),
        if (partial) ...<Widget>[
          const SizedBox(height: AbSpace.sm),
          // The count came back lower than the list submitted. Which devices were dropped is not
          // in the response, so the table marks them all Unconfirmed rather than picking victims.
          NoticeBanner(
            icon: abIcon('exclamationmark.triangle'),
            tone: AbSeverity.drift,
            text:
                'Accepted for ${outcome.devices} of ${_serials.length} selected devices',
            detail:
                'abctl reported fewer devices than were sent, and the response does not say '
                'which. Check the activity\'s result log below, then re-read the device list.',
          ),
        ],
        const SizedBox(height: AbSpace.md),
        Row(
          children: <Widget>[
            Text('Activity', style: AbType.label(context)),
            const SizedBox(width: AbSpace.sm),
            Expanded(
              child: MonoText(outcome.activityID, size: 11.5, color: ab.dim),
            ),
            if (_polling)
              Padding(
                padding: const EdgeInsets.only(right: AbSpace.sm),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: ab.accent,
                  ),
                ),
              ),
            ToolbarButton(
              icon: abIcon('arrow.clockwise'),
              label: 'Check status',
              weight: AbToolbarWeight.titled,
              tooltip:
                  'Run `abctl status activity` for this id. A read — it changes nothing.',
              onPressed: _polling ? null : () => unawaited(_poll()),
            ),
          ],
        ),
        if (activity != null) ...<Widget>[
          const SizedBox(height: AbSpace.xs),
          _kv(ab, 'Status', activity.attr('status') ?? 'unknown'),
          if ((activity.attr('subStatus') ?? '').isNotEmpty)
            _kv(ab, 'Sub-status', activity.attr('subStatus')!),
          if ((activity.attr('createdDateTime') ?? '').isNotEmpty)
            _kv(ab, 'Created', activity.attr('createdDateTime')!),
          if ((activity.attr('completedDateTime') ?? '').isNotEmpty)
            _kv(ab, 'Completed', activity.attr('completedDateTime')!),
        ],
        if (downloadUrl != null && downloadUrl.isNotEmpty) ...<Widget>[
          const SizedBox(height: AbSpace.sm),
          _resultLog(ab, downloadUrl),
        ],
        if (pollFailure != null) ...<Widget>[
          const SizedBox(height: AbSpace.sm),
          AbNote(
            text:
                'Couldn\'t read the activity: ${loadErrorText(pollFailure)} The activity itself is '
                'unaffected — this was only the status read.',
            tone: AbSeverity.drift,
          ),
        ],
      ],
    );
  }

  /// Apple's per-device verdict, which lives in a CSV it publishes when the activity completes.
  ///
  /// The URL is shown and copyable rather than opened: it is a pre-signed link handed to us by a
  /// tenant response, and this app has never opened one — the operator decides where it goes.
  Widget _resultLog(AbColors ab, String url) => Container(
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
            Text('Result log', style: AbType.label(context)),
            const Spacer(),
            CopyButton(
              text: () => url,
              tooltip: 'Copy Apple\'s result-log URL to the clipboard.',
            ),
          ],
        ),
        SelectableText(
          url,
          maxLines: 2,
          style: AbType.mono(context, size: 10.5, color: ab.dim),
        ),
        Text(
          'Apple\'s per-device result for this activity — the only place a device-by-device '
          'verdict exists. abctl can fetch it for you with `status activity --download`.',
          style: TextStyle(fontSize: 10.5, color: ab.faint),
        ),
      ],
    ),
  );

  Widget _failedPanel(AbColors ab) {
    final Object error = _failure ?? 'abctl reported no result.';
    final bool cancelled = error is AbctlCancelled;
    final bool timedOut = error is AbctlTimedOut;
    final AbctlAssignment action = _ranAction ?? _action;

    return Column(
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
              // Three states, not two. "Nothing was submitted" is a positive claim about a live
              // tenant and it is only earned when abctl ITSELF reported the failure — it resolves
              // every serial before it POSTs, so its own refusal really does mean nothing was
              // sent. A watchdog kill earns nothing: abgui killed the child while Apple was
              // answering, and the activity may well exist. This headline used to say "Nothing
              // was submitted" for a timeout while the paragraph six lines below said "if the
              // activity had already been submitted, Apple kept it" — and the headline is what
              // gets read, screenshotted and acted on.
              cancelled
                  ? 'Stopped — what reached Apple is unknown'
                  : (timedOut
                        ? 'Timed out — what reached Apple is unknown'
                        : 'Nothing was submitted'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: ab.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: AbSpace.sm),
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
          text: cancelled || timedOut
              ? '${cancelled ? 'abgui stopped abctl' : 'abgui timed out and killed abctl'} before '
                    'it answered, so abgui does not know whether the activity was submitted. '
                    'abctl resolves every serial BEFORE it submits anything, so an interruption '
                    'during that phase moved no device; an interruption after it means Apple has '
                    'the request and will process it. Re-read the device list to find out which '
                    'happened — do not simply run it again, because a second activity for devices '
                    'Apple already accepted is a duplicate, not a retry.'
              : 'abctl ${action.verb} resolves EVERY serial to a device id before it submits '
                    'anything, and one unknown or ambiguous serial fails the whole command. No '
                    'device was moved. Fix the serial named above and run it again.',
          tone: AbSeverity.drift,
        ),
      ],
    );
  }

  // -- footer --------------------------------------------------------------------------------

  Widget _footer(AbColors ab) {
    final bool ready = _argv != null;
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
                onPressed: () => Navigator.of(context).pop(false),
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
                style: _action == AbctlAssignment.unassign
                    ? FilledButton.styleFrom(
                        backgroundColor: ab.danger,
                        foregroundColor: ab.surface,
                      )
                    : null,
                onPressed: ready ? () => unawaited(_run()) : null,
                child: Text(
                  _action == AbctlAssignment.assign ? 'Assign' : 'Unassign',
                ),
              ),
            ],
            _Stage.running => <Widget>[
              TextButton(
                onPressed: () => _cancel?.cancel(),
                child: const Text('Cancel'),
              ),
            ],
            _Stage.done => <Widget>[
              FilledButton(
                // The result — accepted or not — is what the caller refreshes on.
                onPressed: () => Navigator.of(context).pop(_outcome != null),
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
      _Stage.compose when !ready => 'Choose an MDM server to continue.',
      _Stage.compose =>
        '${_action.verb} ${widget.devices.length} device(s) · $_serverName',
      _Stage.confirm =>
        'This is the confirmation. The next click reaches Apple Business.',
      _Stage.running =>
        'Cancel stops abctl; it does not recall an activity Apple already has.',
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

  Widget _kv(AbColors ab, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: AbSpace.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(width: 110, child: Text(label, style: AbType.label(context))),
        Expanded(child: MonoText(value, size: 11.5, color: ab.dim)),
      ],
    ),
  );
}
