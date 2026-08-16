// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The gate in front of `abctl seed` — the verb that turns a plain folder into a GitOps
/// workspace by downloading live tenant state into it.
///
/// **Two different questions wear one dialog, and the difference is the whole point.** Seeding an
/// EMPTY folder creates something out of nothing: there is no prior state to lose, and the dialog
/// is an explanation with a button on it. Seeding a folder that already has a `gitops/` tree
/// OVERWRITES a git checkout with whatever Apple Business happens to hold right now — including
/// over a profile somebody edited this morning and has not synced yet. That is the destructive
/// case, it looks identical from the outside, and it is the one this file exists for.
///
/// The answer is a [SeedConsent], not a bool, and it is handed to a store that REFUSES the
/// overwrite unless it is given the overwrite value. A screen cannot seed over a tree by
/// forgetting to ask — there is no `seed()` for it to call that would let it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_args.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/command_preview.dart';

class SeedWorkspaceDialog extends ConsumerWidget {
  const SeedWorkspaceDialog({
    super.key,
    required this.workspace,
    required this.hasTree,
  });

  /// The folder abctl will run in, and therefore the folder `gitops/` resolves against.
  final String workspace;

  /// Whether that folder already has a tree. Passed in rather than stat-ed here: a dialog's
  /// `build` runs again on every theme change and window resize, and a filesystem call inside one
  /// is the same class of mistake as reading a profile there.
  final bool hasTree;

  /// Ask. Null means the user said no — including by dismissing, which is a no.
  static Future<SeedConsent?> confirm(
    BuildContext context, {
    required String workspace,
    required bool hasTree,
  }) => showDialog<SeedConsent>(
    context: context,
    builder: (BuildContext context) =>
        SeedWorkspaceDialog(workspace: workspace, hasTree: hasTree),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;

    return AlertDialog(
      backgroundColor: ab.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AbSpace.radius),
        side: BorderSide(color: ab.line),
      ),
      title: Row(
        children: <Widget>[
          Icon(
            abIcon(hasTree ? 'exclamationmark.triangle' : 'folder.badge.plus'),
            size: 16,
            color: hasTree ? ab.danger : ab.accent,
          ),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Text(
              hasTree
                  ? 'Re-seed this workspace from the tenant?'
                  : 'Initialize this folder from the tenant?',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: ab.text,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'abctl downloads the live configurations and blueprints into '
              '$workspace${_separator(workspace)}gitops/, plus a baseline for the 3-way diff. '
              'It READS Apple Business and writes local files — nothing about the tenant '
              'changes.',
              style: TextStyle(fontSize: 12, color: ab.text, height: 1.45),
            ),
            if (hasTree) ...<Widget>[
              const SizedBox(height: AbSpace.sm),
              // The only sentence in this dialog that describes a loss, so it gets the colour and
              // it says exactly what is lost rather than "existing data".
              Container(
                decoration: BoxDecoration(
                  color: AbSeverity.danger.ground(ab),
                  border: Border.all(color: AbSeverity.danger.edge(ab)),
                  borderRadius: BorderRadius.circular(AbSpace.radius),
                ),
                padding: const EdgeInsets.all(AbSpace.sm),
                child: Text(
                  'This folder already has a gitops/ tree. Seeding rewrites it from what Apple '
                  'Business holds right now, so any local edit that has not been synced is '
                  'replaced by the live version — and git is the only place those edits still '
                  'exist afterwards. Commit or stash first if you are unsure.',
                  style: TextStyle(
                    fontSize: 12,
                    color: ab.danger,
                    height: 1.45,
                  ),
                ),
              ),
            ],
            const SizedBox(height: AbSpace.sm),
            Text(
              'It is slow on a large tenant — every configuration is fetched in full — and abctl '
              'narrates as it goes, so the progress pane below the plan is where to watch it. '
              'Cancelling mid-way leaves a half-written tree; re-seeding fixes that.',
              style: TextStyle(fontSize: 12, color: ab.dim, height: 1.45),
            ),
            const SizedBox(height: AbSpace.md),
            CommandPreview(
              base: AbctlArgs.seed(),
              // The workspace IS the argument here: `seed` has no path flag, it writes into the
              // directory it runs in. A preview without the `cd` would be a command that seeds
              // wherever the terminal happened to be.
              cwd: workspace,
              caption:
                  'No --yes: there is no tenant change to gate. The confirmation is about this '
                  'folder, which is why abgui asks rather than abctl.',
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        // The consent value travels with the answer: whichever button was pressed is what the
        // store is told, and the store refuses the overwrite unless it hears the overwrite word.
        FilledButton(
          style: hasTree
              ? FilledButton.styleFrom(backgroundColor: ab.danger)
              : null,
          onPressed: () => Navigator.of(context).pop(
            hasTree
                ? SeedConsent.overwriteExistingTree
                : SeedConsent.onlyIfAbsent,
          ),
          child: Text(hasTree ? 'Re-seed' : 'Initialize'),
        ),
      ],
    );
  }

  /// Whichever separator the path is already spelled with, so the sentence reads as one path
  /// rather than as a Windows path with a stray forward slash glued on.
  static String _separator(String path) => path.contains('\\') ? '\\' : '/';
}
