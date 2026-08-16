// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/models/run_log_file.dart';
import 'package:abgui/src/platform/app_paths.dart';
import 'package:abgui/src/platform/reveal_in_file_manager.dart';
import 'package:abgui/src/state/load_token.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

import 'diagnostics_chrome.dart';

/// The log viewer: every run abgui has recorded, readable inside the app.
///
/// The transcripts have always been written to disk, but reaching them meant knowing where, and
/// knowing the file manager. That is a fine ask of a developer and a poor one of the
/// administrator standing in front of a sync that failed — so the logs come to them: pick a run,
/// read what abctl actually printed, copy it or reveal it for a bug report.
///
/// Everything here is filesystem-only. No abctl, no network, no credentials — which matters,
/// because a broken connection is exactly when someone needs this screen.
class RunLogsScreen extends ConsumerStatefulWidget {
  const RunLogsScreen({super.key});

  @override
  ConsumerState<RunLogsScreen> createState() => _RunLogsScreenState();
}

class _RunLogsScreenState extends ConsumerState<RunLogsScreen> {
  /// Two generations, not one, for the reason `LoadGeneration` was written down: a re-scan and a
  /// file read are different concerns, and sharing a counter means selecting a log while a scan
  /// is in flight orphans the READ — leaving a spinner over a transcript that had already loaded.
  final LoadGeneration _scans = LoadGeneration('runLogs.scan');
  final LoadGeneration _reads = LoadGeneration('runLogs.read');

  String? _directory;
  List<RunLogFile> _logs = const <RunLogFile>[];
  bool _scanning = false;

  /// The selection is a PATH, not an index or a row: a re-scan rebuilds every `RunLogFile`, and
  /// the pruner can delete a file out from under the list between two scans.
  String? _selectedPath;

  String? _contents;
  List<String> _lines = const <String>[];
  bool _reading = false;
  bool _readFailed = false;
  bool _revealFailed = false;

  String _filter = '';

  /// The transcript pane's own scroll position — see the note where it is attached.
  final ScrollController _transcriptScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _transcriptScroll.dispose();
    super.dispose();
  }

  RunLogFile? get _selected {
    final path = _selectedPath;
    if (path == null) return null;
    for (final RunLogFile log in _logs) {
      if (log.path == path) return log;
    }
    return null;
  }

  /// Re-scan the log directory.
  ///
  /// **Off the main isolate**, and not as a matter of taste: `RunLogIndex.scan` stats every file
  /// in the directory and probes the TAIL of each one for its footer — up to fifty opens, seeks
  /// and reads, all of them synchronous `dart:io`. On the platform thread that is a visible
  /// stall on a slow or network volume, and it is the same "work written as an expression looks
  /// free" mistake as decoding a profile inside a build method.
  Future<void> _reload() async {
    final token = _scans.begin();
    setState(() {
      _scanning = true;
      _revealFailed = false;
    });

    // Resolving the directory CREATES it (owner-only), so a first run with no logs yet still
    // shows a real path to copy instead of an empty string.
    final String? directory = await AppPaths.runLogDirectory();
    List<RunLogFile> found = const <RunLogFile>[];
    if (directory != null) {
      final String target = directory;
      found = await Isolate.run(() => RunLogIndex.scan(target));
    }
    if (!mounted || token.isStale) return;

    setState(() {
      _directory = directory;
      _logs = found;
      _scanning = false;
      // Keep the current selection if it survived the re-scan; otherwise open the newest, which
      // is the run someone almost always came here to read. `scan` sorts newest first.
      final String? keep = _selectedPath;
      final bool survived =
          keep != null && found.any((RunLogFile log) => log.path == keep);
      if (!survived) {
        _selectedPath = found.isEmpty ? null : found.first.path;
      }
    });
    await _readSelected();
  }

  /// Load the selected transcript.
  ///
  /// The read is off-isolate for the same reason as the scan — `RunLog` caps one file at 5 MiB,
  /// and a synchronous read plus UTF-8 decode of that size is far past a frame budget. The SPLIT
  /// stays here: shipping ~50,000 individual strings back across an isolate boundary costs more
  /// than one linear pass over a string that has already been decoded.
  Future<void> _readSelected() async {
    final String? path = _selectedPath;
    if (path == null) {
      if (!mounted) return;
      setState(() {
        _contents = null;
        _lines = const <String>[];
        _reading = false;
        _readFailed = false;
      });
      return;
    }

    final token = _reads.begin();
    setState(() {
      _reading = true;
      _revealFailed = false;
    });
    final String? text = await Isolate.run(() => RunLogIndex.contents(path));
    // The selection can change while a large log is being read; publishing a stale one would
    // show the wrong transcript under the right filename.
    if (!mounted || token.isStale) return;

    setState(() {
      _contents = text;
      _lines = text == null
          ? const <String>[]
          : const LineSplitter().convert(text);
      _reading = false;
      _readFailed = text == null;
    });
  }

  Future<void> _reveal() async {
    final RunLogFile? log = _selected;
    if (log == null) return;
    final bool ok = await RevealInFileManager.reveal(log.path);
    if (!mounted) return;
    // Best-effort by design: a desktop with no file manager (or a sandboxed one) must not raise
    // a dialog over a log the user can already read, copy and locate by path.
    setState(() => _revealFailed = !ok);
  }

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final density = ref.watch(settingsProvider.select((s) => s.density));
    final RunLogFile? selected = _selected;

    return ScreenScaffold(
      title: 'Logs',
      subtitle: _directory,
      banner: _directory == null && !_scanning
          ? NoticeBanner(
              tone: AbSeverity.danger,
              icon: abIcon('exclamationmark.triangle'),
              text: 'abgui has nowhere to write run logs',
              detail:
                  'Its log directory could not be created, so nothing is being recorded. A '
                  'read-only home directory or a sandbox denial is the usual cause.',
            )
          : null,
      actions: <Widget>[
        ScreenSearchField(
          hint: 'Filter logs',
          onChanged: (String value) => setState(() => _filter = value),
        ),
        CopyButton(
          text: () => _contents ?? '',
          enabled: _contents != null,
          label: 'Copy log',
          weight: AbToolbarWeight.titled,
          tooltip:
              'Copy the whole transcript to the clipboard, ready to paste into a bug report.',
        ),
        ToolbarButton(
          icon: abIcon('folder'),
          label: 'Reveal',
          tooltip: 'Show this log file in your file manager.',
          onPressed: selected == null ? null : () => unawaited(_reveal()),
        ),
        ToolbarButton(
          icon: abIcon('arrow.clockwise'),
          label: 'Refresh',
          tooltip: 'Re-scan the log directory for new runs.',
          onPressed: _scanning ? null : () => unawaited(_reload()),
        ),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 380,
            child: AbTable<RunLogFile>(
              rows: _logs,
              columns: _columns,
              rowId: (RunLogFile log) => log.path,
              filter: _filter,
              density: density,
              isLoading: _scanning,
              selectionMode: AbSelectionMode.single,
              severity: _severityOf,
              semanticsLabel: 'Run logs',
              reportsStatus: true,
              onSelectionChanged: (List<RunLogFile> picked) {
                setState(
                  () =>
                      _selectedPath = picked.isEmpty ? null : picked.first.path,
                );
                unawaited(_readSelected());
              },
              emptyIcon: abIcon('doc.text.magnifyingglass'),
              emptyTitle: 'No run logs yet',
              emptyMessage:
                  'abgui writes a transcript for every diff, seed and sync — what it ran, what '
                  'abctl printed, how long each step took and how the run ended. Run one from '
                  'Diff and it will appear here.',
              // No `error:` and therefore no `errorAction:`. A scan cannot fail into a message:
              // `RunLogIndex.scan` answers with an empty list for an unreadable directory, and
              // the only genuine failure — no log directory at all — is a fact about the whole
              // screen and is stated in the banner above, not inside the list.
            ),
          ),
          Container(width: 1, color: ab.line),
          Expanded(child: _detail(ab, selected)),
        ],
      ),
    );
  }

  Widget _detail(AbColors ab, RunLogFile? log) {
    if (log == null) {
      return ColoredBox(
        color: ab.surface,
        child: EmptyState(
          icon: abIcon('sidebar.left'),
          title: 'Select a run',
          message: 'Pick a log on the left to read what that run did.',
        ),
      );
    }

    return ColoredBox(
      color: ab.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(AbSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SelectableMono(log.name, weight: FontWeight.w600),
                const SizedBox(height: 2),
                Text(
                  _metaLine(log),
                  style: TextStyle(fontSize: 11, color: ab.faint),
                ),
                const SizedBox(height: AbSpace.sm),
                // Said HERE, beside the copy button, and not buried in a help page: this is the
                // moment someone is about to paste a transcript into an email. Credentials are
                // the only thing the log format guarantees to omit — the file still names the
                // tenant and everything in it.
                Text(
                  'Safe to share with the developer, with one caveat: logs contain no '
                  'credentials, but they do name your organization, configurations, blueprints, '
                  'device serials and user email addresses. Read before sending.',
                  style: TextStyle(fontSize: 11, color: ab.faint, height: 1.45),
                ),
                if (_revealFailed) ...<Widget>[
                  const SizedBox(height: AbSpace.xs),
                  Text(
                    'Couldn\'t open a file manager here. The path is in the header above and is '
                    'selectable.',
                    style: TextStyle(fontSize: 11, color: ab.drift),
                  ),
                ],
              ],
            ),
          ),
          Container(height: 1, color: ab.line),
          Expanded(child: _transcript(ab)),
        ],
      ),
    );
  }

  Widget _transcript(AbColors ab) {
    if (_reading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_readFailed) {
      return EmptyState(
        icon: abIcon('exclamationmark.triangle'),
        title: 'Couldn\'t read this log',
        message:
            'The file may have been pruned or moved since the last scan. Refresh to re-scan.',
        tone: AbSeverity.danger,
      );
    }
    if (_lines.isEmpty) {
      return EmptyState(
        icon: abIcon('doc.text'),
        title: 'This log is empty',
        message: 'The run was interrupted before anything reached the file.',
      );
    }

    // One line per row, built lazily.
    //
    // The obvious rendering — the whole file in a single `SelectableText` — is the performance
    // cliff `docs/abgui-flutter-port.md` warns about by name: Flutter lays out and paints the
    // entire block, and a 5 MiB transcript (the writer's own per-file cap) makes selection
    // quadratic. A `ListView.builder` builds only what is on screen, and `SelectionArea` keeps
    // selection working ACROSS lines, which is the half of the behaviour that matters here — the
    // Copy button already covers "I want all of it".
    return SelectionArea(
      child: Scrollbar(
        // An EXPLICIT controller, shared with the list below it. Without one the scrollbar falls
        // back to the window's PrimaryScrollController — which every other screen in the shell's
        // IndexedStack is also alive inside, so the bar ends up attached to two positions (or to
        // none) depending on which panes the user has opened. Owning the controller makes the
        // pairing local and therefore true.
        controller: _transcriptScroll,
        child: ListView.builder(
          controller: _transcriptScroll,
          padding: const EdgeInsets.symmetric(
            horizontal: AbSpace.lg,
            vertical: AbSpace.sm,
          ),
          itemCount: _lines.length,
          itemBuilder: (BuildContext context, int index) => Text(
            _lines[index],
            style: AbType.mono(context, size: 11.5, color: ab.dim),
          ),
        ),
      ),
    );
  }

  static String _metaLine(RunLogFile log) {
    final parts = <String>[
      AbRelativeTime.absolute(log.startedAt ?? log.modifiedAt),
      log.sizeText,
    ];
    final duration = log.duration;
    if (duration != null) parts.add(duration);
    parts.add(log.outcome ?? 'no footer — the run did not finish');
    return parts.join(' · ');
  }

  static AbSeverity _severityOf(RunLogFile log) {
    // Unfinished is not a failure: writing the footer is the last thing a finished run does, so
    // its absence means the app died mid-run — an unknown outcome, which is its own colour.
    if (log.isUnfinished) return AbSeverity.drift;
    return log.isFailure ? AbSeverity.danger : AbSeverity.ok;
  }

  static final List<AbColumn<RunLogFile>> _columns = <AbColumn<RunLogFile>>[
    AbColumn<RunLogFile>(
      header: 'Name',
      value: (RunLogFile log) => log.name,
      type: AbColumnType.mono,
      flex: 3,
      minWidth: 150,
    ),
    AbColumn<RunLogFile>(
      header: 'Verb',
      value: (RunLogFile log) => log.verb,
      type: AbColumnType.mono,
      width: 62,
    ),
    AbColumn<RunLogFile>(
      header: 'Started',
      // The filename's stamp is UTC and therefore comparable across machines; file mtime is the
      // fallback for a name that would not parse.
      value: (RunLogFile log) =>
          (log.startedAt ?? log.modifiedAt).toIso8601String(),
      type: AbColumnType.date,
      width: 104,
    ),
    AbColumn<RunLogFile>(
      header: 'Size',
      value: (RunLogFile log) => log.sizeText,
      type: AbColumnType.number,
      width: 84,
      // Sorted on the byte count, never on the rendered string: "9 KB" and "1.2 MB" compare the
      // wrong way round as text, and a log list sorted by size exists precisely to find the big
      // one.
      compare: (RunLogFile a, RunLogFile b) =>
          a.sizeBytes.compareTo(b.sizeBytes),
    ),
    AbColumn<RunLogFile>(
      header: 'Outcome',
      // A WORD, not the footer's sentence: the badge is scanned down a column, and the full
      // outcome text is one click away in the detail header.
      value: (RunLogFile log) =>
          log.isUnfinished ? 'unfinished' : (log.isFailure ? 'failed' : 'ok'),
      type: AbColumnType.badge,
      severity: _severityOf,
      width: 96,
    ),
  ];
}
