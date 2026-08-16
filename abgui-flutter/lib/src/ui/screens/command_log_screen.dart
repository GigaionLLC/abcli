// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/models/command_record.dart';
import 'package:abgui/src/models/command_timing.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/elapsed_ticker.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

import 'diagnostics_chrome.dart';

/// The session's abctl transcript: every command abgui ran, newest first, in a form that can be
/// pasted into a terminal.
///
/// abgui is a thin facade over the CLI, so this page is two things at once — an audit trail
/// ("what did it just do to my tenant?") and the migration path for an administrator who would
/// rather script it. Nothing here is instrumented per verb: the `RecordingRunner` wraps the one
/// `AbctlRunner.run` seam, so a verb added later is captured without anyone remembering to.
class CommandLogScreen extends ConsumerStatefulWidget {
  const CommandLogScreen({super.key});

  @override
  ConsumerState<CommandLogScreen> createState() => _CommandLogScreenState();
}

class _CommandLogScreenState extends ConsumerState<CommandLogScreen> {
  String _filter = '';

  /// The selected row as an ID, never as an index or a record.
  ///
  /// A record is REPLACED when it finishes (`CommandRecord.copyWith` keeps the id and changes
  /// everything else), so holding the object would freeze the detail pane on the running version
  /// of a command that has since exited — the pane would sit at "running" forever while the row
  /// beside it said exit 0.
  String? _selectedId;

  bool _timingOpen = false;

  /// Memoized reversal of the log.
  ///
  /// `AbTable` re-filters and re-sorts whenever its `rows` list is a different object, and
  /// `records.reversed.toList()` in `build` is a new object every frame — which would re-derive
  /// the whole view on every keystroke in the filter box and twice per command. The log is
  /// replaced wholesale on each change and never mutated, so identity is a sound cache key.
  List<CommandRecord>? _reversedFrom;
  List<CommandRecord> _reversed = const <CommandRecord>[];

  List<CommandRecord> _newestFirst(List<CommandRecord> records) {
    if (identical(records, _reversedFrom)) return _reversed;
    _reversedFrom = records;
    _reversed = records.reversed.toList(growable: false);
    return _reversed;
  }

  CommandRecord? _selected(List<CommandRecord> records) {
    final id = _selectedId;
    if (id == null) return null;
    for (final CommandRecord record in records) {
      if (record.id == id) return record;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final records = ref.watch(commandLogProvider).records;
    final timings = ref.watch(commandTimingProvider);
    final density = ref.watch(settingsProvider.select((s) => s.density));
    final rows = _newestFirst(records);
    final selected = _selected(records);

    return ScreenScaffold(
      title: 'Command Log',
      subtitle: records.isEmpty
          ? null
          : '${records.length} command(s) this session',
      actions: <Widget>[
        ScreenSearchField(
          hint: 'Filter commands',
          onChanged: (String value) => setState(() => _filter = value),
        ),
        CopyButton(
          // Built on press: this concatenates every recorded command, and evaluating it on each
          // render would rebuild the whole transcript twice per command.
          text: () => combinedScript(records),
          enabled: records.isNotEmpty,
          label: 'Copy all as script',
          weight: AbToolbarWeight.titled,
          tooltip:
              'Copy every recorded command, oldest first, as one paste-able shell snippet.',
        ),
        ToolbarButton(
          icon: abIcon('trash'),
          label: 'Clear',
          tooltip:
              'Forget the recorded commands. This empties abgui\'s list only — nothing on '
              'Apple Business or on disk changes.',
          onPressed: records.isEmpty
              ? null
              : () {
                  ref.read(commandLogProvider.notifier).clear();
                  setState(() => _selectedId = null);
                },
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TimingPanel(
            timings: timings,
            records: records,
            density: density,
            isOpen: _timingOpen,
            onToggle: () => setState(() => _timingOpen = !_timingOpen),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: AbTable<CommandRecord>(
                    rows: rows,
                    columns: _columns,
                    rowId: (CommandRecord r) => r.id,
                    filter: _filter,
                    density: density,
                    selectionMode: AbSelectionMode.single,
                    severity: _severityOf,
                    semanticsLabel: 'Recorded abctl commands',
                    // The invocation list, not the timing panel below it: one table per screen
                    // owns the status bar, or the two take turns overwriting each other.
                    reportsStatus: true,
                    onSelectionChanged: (List<CommandRecord> picked) =>
                        setState(
                          () => _selectedId = picked.isEmpty
                              ? null
                              : picked.first.id,
                        ),
                    emptyIcon: abIcon('terminal'),
                    emptyTitle: 'No commands yet',
                    emptyMessage:
                        'Every abctl command abgui runs is recorded here — with its working '
                        'directory, exit code and duration — so you can reproduce it in a '
                        'terminal. Run a diff, a validate or a read and it will show up.',
                  ),
                ),
                Container(width: 1, color: ab.line),
                Expanded(flex: 2, child: _DetailPane(record: selected)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The columns, built once: `AbTable` compares columns by header and type to decide whether its
  /// derived view needs recomputing, so a list rebuilt inline per frame is merely wasteful — but
  /// these close over nothing, so there is no reason to rebuild them at all.
  static final List<AbColumn<CommandRecord>>
  _columns = <AbColumn<CommandRecord>>[
    AbColumn<CommandRecord>(
      header: 'Command',
      // The full redacted line, not the verb: two `get device …` rows differ only in their
      // subject, and the column you scan down has to be the one that tells them apart.
      value: (CommandRecord r) => r.commandLine,
      type: AbColumnType.mono,
      flex: 3,
      minWidth: 220,
    ),
    AbColumn<CommandRecord>(
      header: 'Verb',
      // The same key the timing roll-up groups by, so a verb is called one thing on both
      // halves of this screen.
      value: (CommandRecord r) => CommandTiming.verbKey(r.argv),
      type: AbColumnType.mono,
      width: 132,
    ),
    AbColumn<CommandRecord>(
      header: 'Status',
      value: _statusWord,
      type: AbColumnType.badge,
      severity: _severityOf,
      width: 96,
      // Alphabetical order on a status is meaningless ("cancelled" before "failed" before
      // "ok"). Sort by how much attention the state deserves instead.
      compare: (CommandRecord a, CommandRecord b) =>
          _statusRank(a).compareTo(_statusRank(b)),
    ),
    AbColumn<CommandRecord>(
      header: 'Exit',
      value: _exitText,
      type: AbColumnType.number,
      width: 62,
    ),
    AbColumn<CommandRecord>(
      header: 'Duration',
      value: (CommandRecord r) => r.durationText ?? '—',
      // Mono + tabular, so the tenths line up down the column; sorted on the real Duration
      // rather than on the string, which would put "9.0s" after "1m 4s".
      type: AbColumnType.mono,
      align: TextAlign.right,
      width: 88,
      compare: (CommandRecord a, CommandRecord b) {
        final left = a.duration;
        final right = b.duration;
        // A command still running has no duration and sorts LAST in both directions: it is
        // an unknown, not a zero.
        if (left == null && right == null) return 0;
        if (left == null) return 1;
        if (right == null) return -1;
        return left.compareTo(right);
      },
    ),
    AbColumn<CommandRecord>(
      header: 'Started',
      // ISO-8601, which is what `AbColumnType.date` parses: it renders "3h ago" with the
      // exact instant on hover, and sorts chronologically rather than by string shape.
      value: (CommandRecord r) => r.startedAt.toIso8601String(),
      type: AbColumnType.date,
      width: 120,
    ),
  ];

  static String _statusWord(CommandRecord record) =>
      switch (record.status.kind) {
        CommandStatusKind.running => 'running',
        CommandStatusKind.succeeded => 'ok',
        CommandStatusKind.failed => 'failed',
        CommandStatusKind.cancelled => 'cancelled',
        CommandStatusKind.timedOut => 'timed out',
      };

  /// Failures first, then the ones still in flight, then the settled ones. Cancelled sorts with
  /// the quiet end on purpose — the user asked for it, so it is not news.
  static int _statusRank(CommandRecord record) => switch (record.status.kind) {
    CommandStatusKind.failed => 0,
    CommandStatusKind.timedOut => 1,
    CommandStatusKind.running => 2,
    CommandStatusKind.succeeded => 3,
    CommandStatusKind.cancelled => 4,
  };

  static String _exitText(CommandRecord record) {
    switch (record.status.kind) {
      case CommandStatusKind.succeeded:
        // `CommandStatus.succeeded` carries no code (only the failed case does), so the 0 is
        // written here rather than read from a field that is deliberately null.
        return '0';
      case CommandStatusKind.failed:
        return '${record.status.exitCode ?? -1}';
      case CommandStatusKind.running:
      case CommandStatusKind.cancelled:
      case CommandStatusKind.timedOut:
        // No exit code exists for any of these. An em dash, never a 0 — a reader who skips the
        // status column must not come away believing a killed command succeeded.
        return '—';
    }
  }

  static AbSeverity _severityOf(CommandRecord record) =>
      switch (record.status.kind) {
        CommandStatusKind.running => AbSeverity.drift,
        CommandStatusKind.succeeded => AbSeverity.ok,
        CommandStatusKind.failed => AbSeverity.danger,
        CommandStatusKind.timedOut => AbSeverity.danger,
        CommandStatusKind.cancelled => AbSeverity.neutral,
      };

  /// Every recorded command as one snippet, OLDEST first — a transcript, not a list. A
  /// transcript only reproduces the session if it runs in the order the session ran.
  ///
  /// When every command shared one working directory the `cd` is hoisted to a single line at the
  /// top; otherwise each command keeps its own. That is not tidiness: a tree-relative abctl
  /// command run from the wrong directory does not fail, it silently works on someone else's
  /// `gitops/` tree.
  static String combinedScript(List<CommandRecord> records) {
    if (records.isEmpty) return '';
    final directories = <String>{};
    var everyCommandHasOne = true;
    for (final CommandRecord record in records) {
      final cwd = record.cwd;
      if (cwd == null) {
        everyCommandHasOne = false;
      } else {
        directories.add(cwd);
      }
    }
    if (everyCommandHasOne && directories.length == 1) {
      return <String>[
        'cd ${CommandFormatter.quote(directories.first)}',
        for (final CommandRecord record in records)
          CommandFormatter.script(argv: record.argv, stdin: record.stdin),
      ].join('\n\n');
    }
    return records.map((CommandRecord r) => r.script).join('\n\n');
  }
}

/// Where the time goes, per verb — the panel that turns a chronological log into an answer.
///
/// The rows below tell you what a run DID. This tells you which operation is slow, whether it is
/// slow every time or once, and whether one is still going — the three questions actually asked
/// when the app feels stuck. Nothing here is newly measured: every invocation is already timed at
/// the single runner seam, and `CommandTiming.rollUp` only adds them up.
///
/// It is collapsed by default. Expanded it is an `AbTable`, which is what makes the columns
/// sortable — click Slowest to find the verb to blame, or Runs to find the one being called in a
/// loop.
class _TimingPanel extends StatelessWidget {
  const _TimingPanel({
    required this.timings,
    required this.records,
    required this.density,
    required this.isOpen,
    required this.onToggle,
  });

  final List<CommandTiming> timings;
  final List<CommandRecord> records;
  final AbDensity density;
  final bool isOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final running = <CommandRecord>[
      for (final CommandRecord record in records)
        if (record.status.kind == CommandStatusKind.running) record,
    ];
    if (timings.isEmpty && running.isEmpty) return const SizedBox.shrink();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: ab.surface,
        border: Border(bottom: BorderSide(color: ab.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            button: true,
            expanded: isOpen,
            label: _headline,
            excludeSemantics: true,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AbSpace.lg,
                  vertical: AbSpace.sm,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      abIcon(isOpen ? 'chevron.down' : 'chevron.right'),
                      size: 14,
                      color: ab.faint,
                    ),
                    const SizedBox(width: AbSpace.xs),
                    Flexible(
                      child: Text(
                        _headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: ab.dim),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isOpen)
            SizedBox(
              // A bounded height, because `AbTable` must virtualize and cannot do that inside an
              // unbounded column. Six rows plus the header is enough to see the shape of a
              // session without pushing the log itself off the screen.
              height: 8 * density.rowHeight,
              child: AbTable<CommandTiming>(
                rows: timings,
                columns: _timingColumns,
                rowId: (CommandTiming t) => t.id,
                density: density,
                selectionMode: AbSelectionMode.none,
                semanticsLabel: 'Timing by verb',
                emptyTitle: 'No completed commands yet',
              ),
            ),
          // In-flight commands TICK, because "how long has this been going?" is the whole
          // question when the app looks hung, and a static "running" cannot answer it. Each
          // `ElapsedTicker` owns its own timer at the leaf, so a tick repaints one line of text
          // and nothing else on the screen.
          if (running.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbSpace.lg,
                0,
                AbSpace.lg,
                AbSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final CommandRecord record in running)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: <Widget>[
                          SizedBox(
                            width: 11,
                            height: 11,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: ab.drift,
                            ),
                          ),
                          const SizedBox(width: AbSpace.sm),
                          Text(
                            '${CommandTiming.verbKey(record.argv)} — running',
                            style: TextStyle(fontSize: 11, color: ab.dim),
                          ),
                          const SizedBox(width: AbSpace.xs),
                          ElapsedTicker(
                            startedAt: record.startedAt,
                            finishedAt: record.finishedAt,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String get _headline {
    var finished = 0;
    for (final CommandTiming timing in timings) {
      finished += timing.runs;
    }
    // `rollUp` returns slowest first, so the head is the headline without a second scan.
    final slowest = timings.isEmpty ? null : timings.first;
    if (slowest == null || slowest.slowest == Duration.zero) {
      return 'Timing — no completed commands yet';
    }
    return 'Timing — $finished command(s), slowest: ${slowest.verb} at '
        '${DurationText.short(slowest.slowest)}';
  }

  static final List<AbColumn<CommandTiming>> _timingColumns =
      <AbColumn<CommandTiming>>[
        AbColumn<CommandTiming>(
          header: 'Verb',
          value: (CommandTiming t) => t.verb,
          type: AbColumnType.mono,
          flex: 2,
          minWidth: 140,
        ),
        AbColumn<CommandTiming>(
          header: 'Runs',
          value: (CommandTiming t) => '${t.runs}',
          type: AbColumnType.number,
          width: 66,
        ),
        AbColumn<CommandTiming>(
          header: 'Slowest',
          value: (CommandTiming t) => DurationText.short(t.slowest),
          type: AbColumnType.mono,
          align: TextAlign.right,
          width: 88,
          compare: (CommandTiming a, CommandTiming b) =>
              a.slowest.compareTo(b.slowest),
        ),
        AbColumn<CommandTiming>(
          header: 'Average',
          value: (CommandTiming t) => DurationText.short(t.average),
          type: AbColumnType.mono,
          align: TextAlign.right,
          width: 88,
          compare: (CommandTiming a, CommandTiming b) =>
              a.average.compareTo(b.average),
        ),
        AbColumn<CommandTiming>(
          header: 'Running',
          value: (CommandTiming t) => '${t.running}',
          type: AbColumnType.number,
          width: 76,
        ),
        AbColumn<CommandTiming>(
          header: 'Failed',
          value: (CommandTiming t) => '${t.failures}',
          type: AbColumnType.number,
          width: 70,
        ),
      ];
}

/// One recorded invocation in full: the command, how it ended, and enough context to tell two
/// otherwise identical lines apart.
class _DetailPane extends StatelessWidget {
  const _DetailPane({required this.record});

  final CommandRecord? record;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final selected = record;
    if (selected == null) {
      return ColoredBox(
        color: ab.surface,
        child: EmptyState(
          icon: abIcon('sidebar.left'),
          title: 'Select a command',
          message:
              'Pick a row to see the full command line, where it ran and how it ended.',
        ),
      );
    }

    final stdinBytes = selected.stdin.bytes;
    return ColoredBox(
      color: ab.surface,
      child: SingleChildScrollView(
        // Not the PRIMARY scroll view. Every screen lives in the shell's IndexedStack at once, so
        // a pane that claims the inherited PrimaryScrollController claims it for the whole window
        // — and the second pane that does the same puts two positions on one controller, which is
        // an assertion failure in any Scrollbar that later asks it for a single one.
        primary: false,
        padding: const EdgeInsets.all(AbSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                AbBadge(
                  label: _CommandLogScreenState._statusWord(selected),
                  severity: _CommandLogScreenState._severityOf(selected),
                ),
                const SizedBox(width: AbSpace.sm),
                Expanded(
                  child: Text(
                    CommandTiming.verbKey(selected.argv),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                ),
                // The same ticker the timing strip uses: it freezes the instant the record is
                // replaced by its finished copy, so a selected command that ends stops counting
                // without this pane doing anything.
                ElapsedTicker(
                  startedAt: selected.startedAt,
                  finishedAt: selected.finishedAt,
                ),
              ],
            ),
            const SizedBox(height: AbSpace.md),
            Text('COMMAND', style: AbType.label(context)),
            const SizedBox(height: AbSpace.xs),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AbSpace.sm),
              decoration: BoxDecoration(
                color: ab.sunken,
                border: Border.all(color: ab.line),
                borderRadius: BorderRadius.circular(AbSpace.radius),
              ),
              // Shown exactly as it executed, `-f -` and all: the copy button is where the
              // paste-able rewrite lives, so what is displayed stays literally true.
              child: SelectableMono(selected.commandLine),
            ),
            const SizedBox(height: AbSpace.sm),
            Row(
              children: <Widget>[
                CopyButton(
                  text: () => selected.commandLine,
                  label: 'Copy command',
                  weight: AbToolbarWeight.titled,
                  tooltip: 'Copy this command line to the clipboard.',
                ),
                const SizedBox(width: AbSpace.xs),
                CopyButton(
                  text: () => selected.script,
                  label: 'Copy with cd',
                  weight: AbToolbarWeight.titled,
                  tooltip: selected.cwd == null
                      ? 'Copy this command to the clipboard.'
                      : 'Copy this command with the cd into the workspace, so a tree-relative '
                            'verb resolves the same gitops/ tree abgui used.',
                ),
              ],
            ),
            const SizedBox(height: AbSpace.lg),
            CopyableField(
              label: 'Started',
              value: AbRelativeTime.absolute(selected.startedAt),
            ),
            CopyableField(
              label: 'Finished',
              value: selected.finishedAt == null
                  ? ''
                  : AbRelativeTime.absolute(selected.finishedAt!),
              placeholder: 'still running',
            ),
            CopyableField(
              label: 'Duration',
              value: selected.durationText ?? '',
              placeholder: '—',
            ),
            CopyableField(label: 'Outcome', value: selected.statusText),
            CopyableField(
              label: 'Working directory',
              value: selected.cwd ?? '',
              // Load-bearing, not decoration: the same `abctl diff` line means something
              // different in another folder, because abctl roots `gitops/` at its cwd.
              placeholder: 'abgui ran this outside any workspace',
            ),
            if (stdinBytes != null)
              CopyableField(
                label: 'Stdin',
                value: 'profile on stdin ($stdinBytes bytes)',
              ),
            const SizedBox(height: AbSpace.lg),
            Text('WHERE THE OUTPUT IS', style: AbType.label(context)),
            const SizedBox(height: AbSpace.xs),
            // DELIBERATE GAP, and worth stating rather than leaving to be discovered: this screen
            // records the COMMAND, not what it printed.
            //
            // Capturing both streams per record would mean holding a whole tenant's JSON — a
            // `get devices` payload is tens of megabytes — for up to two hundred commands, in a
            // process that is often mid-plan. Worse, it would put whatever abctl prints behind a
            // copy button on the one screen designed to be pasted into a ticket, and abctl has a
            // verb (`auth token --raw`) whose entire stdout is a live bearer token. `CommandRecord`
            // exists so that a record holding a secret cannot be constructed; adding an unredacted
            // stdout field would quietly undo that.
            //
            // Nothing is lost: the streams are kept where they can be bounded and attributed.
            Text(
              'abgui records the command, not its output — a payload can be tens of megabytes, '
              'and abctl has verbs whose stdout is a live token. What abctl printed is kept '
              'where it belongs: in the run log for diff, seed and sync (Logs), and beside the '
              'command in Console for anything you typed there.',
              style: TextStyle(fontSize: 11, color: ab.faint, height: 1.45),
            ),
            const SizedBox(height: AbSpace.md),
            Text(
              'Credentials are redacted before a command is recorded (--vpp-token ****). A '
              'command still names your connection, configurations and devices, so review one '
              'before sharing it.',
              style: TextStyle(fontSize: 11, color: ab.faint, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
