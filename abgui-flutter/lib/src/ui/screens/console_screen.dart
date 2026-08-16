// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/models/command_line_parser.dart';
import 'package:abgui/src/state/console_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

import 'diagnostics_chrome.dart';

/// Type an abctl command; the connection is already threaded.
///
/// The GUI will always cover less than the CLI it wraps. Rather than pretend otherwise, this is
/// the escape hatch: the read surface of the tool, run against the SAME tenant and the SAME
/// workspace the buttons use, with `--context` appended for you. No copying a client id into a
/// terminal, no remembering which directory `gitops/` resolves against — the mismatch that made
/// GUI commands land in the wrong tree is exactly what this removes.
///
/// **What the console will not do, now that the app writes.** A mutating verb typed here is
/// refused, with the reason and with the screen that does perform it, and nothing is spawned.
/// This is not a missing feature: abgui writes from surfaces that put a plan, a confirmation and
/// a receipt around the command, and a text field is a second door past all of it. The refusal is
/// enforced one layer down, by `ConsoleGuard` inside `ConsoleStore` — the disabled-looking hint
/// below the prompt is a courtesy, not the guarantee. See `state/console_store.dart`.
class ConsoleScreen extends ConsumerStatefulWidget {
  const ConsoleScreen({super.key});

  @override
  ConsumerState<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends ConsumerState<ConsoleScreen> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'console prompt');
  final ScrollController _scroll = ScrollController();

  /// Where the up-arrow walk has got to, as an index into the store's history. Null means "at the
  /// live prompt", which is a different state from "at the newest history entry" — walking down
  /// off the end has to return the empty line the user was typing.
  int? _historyIndex;

  /// Entries whose full output the user asked for. Keyed by entry id so the set survives new
  /// entries arriving above (and below) an expanded one.
  final Set<String> _expanded = <String>{};

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _submit() {
    final String line = _input.text;
    if (CommandLineParser.tokenize(line).isEmpty) return;
    if (ref.read(consoleProvider).isRunning) return;
    _input.clear();
    _historyIndex = null;
    // Deliberately NOT gated on `ConsoleGuard` here. A refused command still becomes a transcript
    // entry carrying its reason, because a prompt that silently swallows what you typed is
    // indistinguishable from an app that has frozen.
    unawaited(ref.read(consoleProvider.notifier).run(line));
    _focus.requestFocus();
  }

  /// Shell-style recall: up walks back through what you typed, down walks forward and out.
  void _recall(int delta) {
    final List<String> history = ref.read(consoleProvider).history;
    if (history.isEmpty) return;
    final int? current = _historyIndex;
    final int next;
    if (current == null) {
      // Down, at the live prompt: there is nothing to walk forward into.
      if (delta > 0) return;
      next = history.length - 1;
    } else {
      next = current + delta;
    }
    if (next < 0) return; // already at the oldest command
    if (next >= history.length) {
      _historyIndex = null;
      _setInput('');
      return;
    }
    _historyIndex = next;
    _setInput(history[next]);
  }

  /// Replace the prompt and put the caret at the END. Without the explicit selection the caret
  /// stays at offset 0 and the next keystroke types into the middle of the recalled command.
  void _setInput(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final ConsoleState console = ref.watch(consoleProvider);
    final String activeContext = ref.watch(activeContextProvider);
    final String? workspace = ref.watch(workspaceProvider);

    // Follow the tail when a new entry lands. A listener rather than a post-build scroll on every
    // rebuild: the transcript must NOT jump while someone is scrolled up reading an old entry and
    // a keystroke rebuilds the prompt.
    ref.listen<ConsoleState>(consoleProvider, (
      ConsoleState? previous,
      ConsoleState next,
    ) {
      if (previous != null && previous.entries.length == next.entries.length) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    });

    return ScreenScaffold(
      title: 'Console',
      subtitle:
          '${activeContext.isEmpty ? 'abctl\'s current context' : '--context $activeContext'}'
          ' · ${workspace ?? 'no workspace folder chosen'}',
      banner: NoticeBanner(
        icon: abIcon('lock'),
        text: 'Reads only',
        detail:
            'This release runs reads, diff and validate. A command that would change Apple '
            'Business, your workspace tree or your saved connections is refused, not run.',
      ),
      actions: <Widget>[
        ToolbarButton(
          icon: abIcon('trash'),
          label: 'Clear',
          tooltip:
              'Clear this session\'s console output. Nothing on Apple Business or on disk is '
              'removed, and your command history is kept.',
          onPressed: console.entries.isEmpty
              ? null
              : ref.read(consoleProvider.notifier).clear,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AbSpace.lg,
              AbSpace.md,
              AbSpace.lg,
              AbSpace.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Runs the embedded abctl with your connection already applied: --context is '
                  'appended for you and the command runs in your workspace folder, so '
                  'tree-relative verbs resolve the same gitops/ tree the rest of the app uses.',
                  style: TextStyle(fontSize: 12, color: ab.dim, height: 1.4),
                ),
                const SizedBox(height: 3),
                Text(
                  'This is not a shell: no pipes, redirection or variable expansion. Quotes and '
                  'backslashes work. Output is shown exactly as abctl printed it — including '
                  'anything you asked it to print — so review an entry before pasting it.',
                  style: TextStyle(fontSize: 11, color: ab.faint, height: 1.4),
                ),
              ],
            ),
          ),
          Container(height: 1, color: ab.line),
          Expanded(child: _transcript(ab, console)),
          Container(height: 1, color: ab.line),
          _prompt(ab, console),
        ],
      ),
    );
  }

  Widget _transcript(AbColors ab, ConsoleState console) {
    if (console.entries.isEmpty) {
      return ColoredBox(
        color: ab.surface,
        child: EmptyState(
          icon: abIcon('chevron.left.forwardslash.chevron.right'),
          title: 'Nothing run yet',
          message:
              'Try `get blueprints`, `status device <serial>`, `validate --json` or `diff '
              '--json`. Every command is recorded in the Command Log as well.',
        ),
      );
    }
    return ColoredBox(
      color: ab.surface,
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: AbSpace.lg),
          itemCount: console.entries.length,
          itemBuilder: (BuildContext context, int index) {
            final ConsoleEntry entry = console.entries[index];
            return _ConsoleEntryRow(
              entry: entry,
              isExpanded: _expanded.contains(entry.id),
              onToggleExpanded: () => setState(() {
                if (!_expanded.remove(entry.id)) _expanded.add(entry.id);
              }),
            );
          },
        ),
      ),
    );
  }

  Widget _prompt(AbColors ab, ConsoleState console) {
    return Container(
      color: ab.raised,
      padding: const EdgeInsets.fromLTRB(
        AbSpace.lg,
        AbSpace.sm,
        AbSpace.lg,
        AbSpace.sm,
      ),
      // Only this subtree rebuilds as the command is typed. The transcript above can hold a
      // hundred entries of clamped output; re-running its build on every keystroke — to update a
      // hint and a disabled flag — is the same "one notification per keystroke" mistake the
      // progress sink exists to avoid, one layer up.
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _input,
        builder: (BuildContext context, TextEditingValue value, _) {
          final List<String> argv = CommandLineParser.tokenize(value.text);
          final String? refusal = ConsoleGuard.refusal(argv);
          final bool canRun = argv.isNotEmpty && !console.isRunning;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    'abctl',
                    style: AbType.mono(context, size: 13, color: ab.faint),
                  ),
                  const SizedBox(width: AbSpace.sm),
                  Expanded(
                    // A `Shortcuts` placed HERE, immediately around the field, is what lets the
                    // arrows mean history: shortcut resolution walks up from the focused node and
                    // takes the first match, so this wins over `DefaultTextEditingShortcuts` far
                    // above it. On a single-line field the arrows have nothing else to do.
                    child: Shortcuts(
                      shortcuts: const <ShortcutActivator, Intent>{
                        SingleActivator(LogicalKeyboardKey.arrowUp):
                            _RecallIntent(-1),
                        SingleActivator(LogicalKeyboardKey.arrowDown):
                            _RecallIntent(1),
                      },
                      child: Actions(
                        actions: <Type, Action<Intent>>{
                          _RecallIntent: CallbackAction<_RecallIntent>(
                            onInvoke: (_RecallIntent intent) {
                              _recall(intent.delta);
                              return null;
                            },
                          ),
                        },
                        child: TextField(
                          controller: _input,
                          focusNode: _focus,
                          autofocus: true,
                          style: AbType.mono(context, size: 13),
                          cursorColor: ab.accent,
                          onSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'get devices --filter serialNumber=C02',
                            hintStyle: AbType.mono(
                              context,
                              size: 13,
                              color: ab.faint,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (console.isRunning) ...<Widget>[
                    const SizedBox(width: AbSpace.sm),
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: ab.accent,
                      ),
                    ),
                    const SizedBox(width: AbSpace.xs),
                    ToolbarButton(
                      icon: abIcon('stop.circle'),
                      label: 'Cancel',
                      tooltip:
                          'Stop the running command. abctl is killed; anything it had already '
                          'read is unaffected.',
                      onPressed: ref.read(consoleProvider.notifier).cancel,
                    ),
                  ],
                  const SizedBox(width: AbSpace.sm),
                  ToolbarButton(
                    icon: abIcon('chevron.right'),
                    label: 'Run',
                    tooltip: 'Run this command (Enter).',
                    weight: AbToolbarWeight.titled,
                    onPressed: canRun ? _submit : null,
                  ),
                ],
              ),
              if (refusal != null) ...<Widget>[
                const SizedBox(height: AbSpace.xs),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(abIcon('lock'), size: 13, color: ab.drift),
                    const SizedBox(width: AbSpace.xs),
                    Expanded(
                      child: Text(
                        refusal,
                        style: TextStyle(
                          fontSize: 11,
                          color: ab.drift,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// One command and its two streams.
///
/// stdout and stderr stay visually distinct because abctl puts the machine payload on one and the
/// human narration on the other; merging them is how a JSON document becomes unparseable and a
/// hundred lines of progress become "the error".
class _ConsoleEntryRow extends StatelessWidget {
  const _ConsoleEntryRow({
    required this.entry,
    required this.isExpanded,
    required this.onToggleExpanded,
  });

  /// How many lines of a stream are shown before the row offers the rest. Long enough for a
  /// short payload or an error in full, short enough that one `get devices` does not bury every
  /// other entry in the transcript.
  static const int previewLines = 20;

  final ConsoleEntry entry;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final String? reason = entry.notRun;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AbSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: SelectableMono('\$ ${entry.commandLine}', size: 12),
              ),
              const SizedBox(width: AbSpace.sm),
              AbBadge(
                label: entry.statusText,
                severity: entry.refused
                    ? AbSeverity.drift
                    : (entry.isFailure ? AbSeverity.danger : AbSeverity.ok),
              ),
              const SizedBox(width: AbSpace.xs),
              CopyButton(
                text: () => entry.transcript,
                tooltip: 'Copy this command and everything it printed.',
                label: 'Copy entry',
              ),
            ],
          ),
          if (reason != null) ...<Widget>[
            const SizedBox(height: AbSpace.xs),
            Text(
              reason,
              // A refusal is not a failure: nothing was attempted, so it is drawn as the
              // "needs your attention" colour rather than the one that means something broke.
              style: TextStyle(
                fontSize: 11.5,
                color: entry.refused ? ab.drift : ab.danger,
                height: 1.4,
              ),
            ),
          ],
          _stream(context, entry.stdout, color: ab.text),
          _stream(context, entry.stderr, color: ab.dim),
          Container(
            margin: const EdgeInsets.only(top: AbSpace.sm),
            height: 1,
            color: ab.lineSoft,
          ),
        ],
      ),
    );
  }

  Widget _stream(BuildContext context, String raw, {required Color color}) {
    final String text = raw.trimRight();
    if (text.isEmpty) return const SizedBox.shrink();
    final List<String> lines = const LineSplitter().convert(text);
    final bool clipped = !isExpanded && lines.length > previewLines;
    final String shown = clipped
        ? lines.sublist(0, previewLines).join('\n')
        : text;
    return Padding(
      padding: const EdgeInsets.only(top: AbSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SelectableMono(shown, size: 11.5, color: color),
          if (clipped || isExpanded)
            // A disclosure, not a nested scroll view: a scrollable inside the transcript's own
            // scrollable steals the wheel the moment the pointer crosses it, which makes a long
            // console impossible to read past.
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onToggleExpanded,
                child: Text(
                  clipped
                      ? 'Show all ${lines.length} lines'
                      : 'Collapse output',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Walk the command history. `-1` is older, `+1` is newer.
class _RecallIntent extends Intent {
  const _RecallIntent(this.delta);

  final int delta;
}
