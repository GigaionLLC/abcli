// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/models/command_record.dart';
import 'package:abgui/src/state/command_log_store.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/state/progress_sink.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/shell/sidebar_item.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/elapsed_ticker.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// The running command, pinned above the status bar. **Never modal.**
///
/// This strip is the replacement for the modal-progress pattern, and the reason is the bug it was
/// built from: while abctl computed a plan the Swift window blanked — sidebar included — so the
/// only thing on screen was a spinner, and the user could neither read the table they already had
/// nor find out whether the run was progressing or wedged. Everything here is designed against
/// that:
///
///  * **It is a sibling, not an overlay.** The content pane keeps its rows, its scroll position
///    and its selection while a command runs, and the sidebar keeps working.
///  * **It says what is running, exactly.** The redacted argv, straight from `CommandFormatter`
///    via [CommandRecord.commandLine] — the same string the Command Log and every copy button
///    show, so what the user watches and what they can paste into a terminal cannot drift.
///  * **It answers "is it stuck?".** A spinner cannot; a live elapsed time and abctl's own last
///    narration line can.
///  * **It can be stopped.** Cancel terminates the child through the run's `CancelToken`.
///
/// **Rebuild containment.** Three independent clocks meet here and NONE of them may reach the
/// content pane. The elapsed reading lives in [ElapsedTicker], whose timer sits at the leaf. The
/// narration line lives in a `ValueListenableBuilder` on the progress sink's notifier, which is
/// not a provider precisely so a burst of stderr cannot invalidate anything above it (see
/// `progress_sink.dart`). This widget itself only watches values that change twice per command:
/// which command is running, and whether the plan can be cancelled.
class RunStrip extends ConsumerWidget {
  const RunStrip({super.key});

  static const double height = 28;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final CommandRecord? record = ref.watch(
      commandLogProvider.select(newestRunning),
    );
    // Nothing running: draw NOTHING. A permanently reserved 28px band would be 28px of window
    // spent on the state the app is in almost all of the time, and an empty strip reads as a
    // control that has stopped working rather than as an app at rest.
    if (record == null) return const SizedBox.shrink();

    // True while one of the two verbs this strip is the only Cancel for is in flight — phrased as
    // something a widget can subscribe to, because `GitopsStore.canCancelWork` is a plain field
    // read and would never tell the button to re-enable itself.
    //
    // The SEED is in this disjunction, not just the plan: seeding is the slowest thing abgui runs,
    // it is the run most likely to be stopped, and a strip that showed `abctl seed` with no Cancel
    // beside it would be advertising the one command that cannot be interrupted. An APPLY is
    // deliberately absent — it runs behind its own dialog, which carries its own Cancel, and a
    // second one out here would be a second place to press for one irreversible operation.
    final bool cancellable = ref.watch(
      gitopsProvider.select(
        (GitopsState s) => s.plan.isRunning || s.seed.isRunning,
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: ab.surface,
        border: Border(top: BorderSide(color: ab.line)),
      ),
      child: SizedBox(
        height: height,
        child: Row(
          children: <Widget>[
            const SizedBox(width: AbSpace.sm),
            // A static mark, not an indeterminate spinner: an animated indicator asks the engine
            // for a frame every vsync for the whole run, and the ticker below already carries the
            // "still alive" signal at two frames a second.
            Icon(abIcon('terminal'), size: 13, color: ab.drift),
            const SizedBox(width: AbSpace.sm),
            Expanded(flex: 5, child: _CommandLine(record: record)),
            const SizedBox(width: AbSpace.md),
            Expanded(
              flex: 4,
              child: _ProgressLine(sink: ref.watch(progressSinkProvider)),
            ),
            const SizedBox(width: AbSpace.sm),
            ElapsedTicker(
              startedAt: record.startedAt,
              finishedAt: record.finishedAt,
            ),
            const SizedBox(width: AbSpace.sm),
            if (cancellable)
              ToolbarButton(
                icon: abIcon('stop.circle'),
                label: 'Cancel',
                // What stopping LEAVES BEHIND, not just what it does. Both verbs this strip can
                // cancel are safe to interrupt and that is exactly why it is worth saying: the
                // Diff strip and the Apply dialog each spell out their own aftermath, and a
                // generic "terminate the command" here would be the one Cancel in the app that
                // does not — which reads as the dangerous one.
                tooltip:
                    'Stop the running abctl. A diff writes nothing, so stopping it changes '
                    'nothing; a seed writes files, so a half-written gitops/ tree stays as it is '
                    '— seed again to finish it. Neither touches Apple Business.',
                weight: AbToolbarWeight.titled,
                // `cancelWork`, not `cancelPlan`: this strip is generic over the workspace verbs,
                // and a Cancel that silently did nothing during a seed is worse than none.
                onPressed: () => ref.read(gitopsProvider.notifier).cancelWork(),
              ),
            const SizedBox(width: AbSpace.xs),
          ],
        ),
      ),
    );
  }
}

/// The newest in-flight invocation, or null.
///
/// Public so the shell's test can state the rule it encodes: with two commands overlapping the
/// strip names the one that started LAST, because that is the one the user just asked for. A
/// strip that showed the older one would report an abandoned background refresh while the click
/// the user is waiting on went unmentioned.
CommandRecord? newestRunning(CommandLog log) {
  for (int i = log.records.length - 1; i >= 0; i--) {
    final CommandRecord record = log.records[i];
    if (record.status.kind == CommandStatusKind.running) return record;
  }
  return null;
}

/// `abctl diff --json --context acme`, redacted, and a way in to the full transcript.
///
/// Clicking opens the Command Log — the one behaviour worth keeping from the Swift connection
/// footer, whose comment put it best: the last-command line should be a way IN to the transcript
/// rather than a dead end. It stays a plain (unselectable) line here for the same reason it did
/// there: the whole line is the button, and the Command Log is where a command gets read, copied
/// and reproduced.
class _CommandLine extends StatelessWidget {
  const _CommandLine({required this.record});

  final CommandRecord record;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final ShellNavigation? navigation = ShellNavigation.maybeOf(context);
    return Tooltip(
      message: '${record.commandLine}\nOpen the Command Log',
      child: Semantics(
        button: navigation != null,
        label: 'Running ${record.commandLine}. Open the Command Log.',
        excludeSemantics: true,
        child: InkWell(
          onTap: navigation == null
              ? null
              : () => navigation.go(ShellDestination.commandLog),
          child: MonoText(record.commandLine, size: 11.5, color: ab.text),
        ),
      ),
    );
  }
}

/// abctl's own narration, last line only.
///
/// **One line, and it is the newest one.** The full transcript belongs to the Diff screen and to
/// the on-disk run log; what this strip owes the user is proof that the run is still moving. A
/// `ValueListenableBuilder` is what keeps that promise cheap: the sink publishes at most once per
/// 100 ms however many hundreds of stderr lines abctl produced in that window, and the rebuild
/// stops at this widget — the strip around it, the sidebar and the content pane are never
/// consulted.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.sink});

  final ProgressSink sink;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    return ValueListenableBuilder<List<String>>(
      valueListenable: sink.lines,
      builder: (BuildContext context, List<String> lines, Widget? _) {
        if (lines.isEmpty) return const SizedBox.shrink();
        return MonoText(lines.last, size: 11, color: ab.dim);
      },
    );
  }
}
