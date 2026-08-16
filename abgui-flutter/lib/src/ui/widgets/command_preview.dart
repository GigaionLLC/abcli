// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/copy_button.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// The exact command a dialog is about to run, spelled out before it runs.
///
/// **Why this is a widget and not three copies of a `Text`.** A gated write asks an administrator
/// to approve a command; if the line on screen is not the argv the client hands the process, the
/// approval was collected for something the operator never saw. `write_safety_test.dart` calls
/// that invariant 2 and pins it at the client seam — this widget is the other half, the one the
/// human reads. Three surfaces need it now (verify, membership, device assignment) and each
/// re-spelling would be a chance for one of them to drift.
///
/// So it takes the CONTEXT-FREE argv straight from `AbctlArgs` and appends the `--context` tail
/// itself, through the very function the run uses ([AbctlClient.previewArgv]). A caller cannot
/// forget the tail, cannot spell it twice, and cannot name a different tenant than the run will.
///
/// [cwd] is the workspace when — and only when — the command resolves `gitops/` against it. It is
/// deliberately absent for a pure tenant call like `assign`: printing a `cd` there would imply a
/// workspace matters to a verb that never touches one. The displayed line never carries the `cd`
/// either way (it is not part of the argv); the COPIED form does, which is where it is useful and
/// where it cannot make the displayed line untrue.
class CommandPreview extends ConsumerWidget {
  const CommandPreview({
    super.key,
    required this.base,
    required this.caption,
    this.cwd,
    this.label = 'Equivalent CLI',
  });

  /// The argv from an `AbctlArgs` builder — no `--context`, no `cd`, nothing hand-spelled.
  final List<String> base;

  /// The sentence under the line: what running it does, and what the gate is. Written for the
  /// person deciding whether to approve, not for a changelog.
  final String caption;

  /// The directory the command runs in, or null when it runs nowhere in particular.
  final String? cwd;

  /// The eyebrow above the line. Overridable for the one case that is NOT what is about to run —
  /// a recovery command offered after a failure — because labelling that "Equivalent CLI" would
  /// claim abgui had run it.
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final List<String> argv = ref.watch(abctlClientProvider).previewArgv(base);
    final String? workspace = cwd;

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
              Text(label, style: AbType.label(context)),
              const Spacer(),
              CopyButton(
                text: () => CommandFormatter.script(argv: argv, cwd: workspace),
                weight: AbToolbarWeight.compact,
                tooltip: workspace == null
                    ? 'Copy this command to the clipboard.'
                    : 'Copy this command, with the cd into the workspace, to the clipboard.',
              ),
            ],
          ),
          // Selectable, because the useful thing to do with a command you are being asked to
          // approve is take part of it somewhere else — a serial, a blueprint name, the whole line.
          SelectableText(
            CommandFormatter.line(argv),
            style: AbType.mono(context, size: 11, color: ab.dim),
          ),
          const SizedBox(height: 2),
          Text(caption, style: TextStyle(fontSize: 10.5, color: ab.faint)),
        ],
      ),
    );
  }
}
