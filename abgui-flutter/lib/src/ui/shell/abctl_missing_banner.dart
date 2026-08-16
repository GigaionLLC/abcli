// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/copy_button.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// The one state the whole window has to be able to explain: there is no abctl to drive.
///
/// **Why this is chrome and not a screen's problem.** abgui is a front-end for one binary; if that
/// binary is missing, every read verb fails and each of the nineteen screens would say so in its
/// own words, at its own moment, in an empty state that looks exactly like "this organization has
/// no devices". The Swift app spelled the sentence at eight call sites and none of them could say
/// where it had looked. Stating it once, above the content, means a first-run window is legible
/// before the user has clicked anything — which matters most on a developer machine, where no
/// binary has been packaged beside the executable yet and this is the literal first frame.
///
/// It draws NOTHING when abctl is present, and it is a sibling of the content in the shell's
/// `Column` — it pushes the panes down by 33px, it never covers them. The failure is not a modal:
/// Logs, the Command Log and What's New are all still worth reading with no CLI at all.
class AbctlMissingBanner extends ConsumerWidget {
  const AbctlMissingBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbctlMissingBinary? missing = ref.watch(abctlMissingProvider);
    if (missing == null) return const SizedBox.shrink();

    return NoticeBanner(
      tone: AbSeverity.danger,
      icon: abIcon('exclamationmark.triangle.fill'),
      text: 'abctl not found — abgui cannot run any command',
      detail: _oneLine(missing),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // The paths are the diagnosis and they are far too long for a 33px strip, so the strip
          // offers them instead of showing them. This is the whole bug report for a packaging
          // fault: which binary was expected, and everywhere it was not.
          CopyButton(
            text: () => missing.message,
            label: 'Copy details',
            weight: AbToolbarWeight.titled,
            tooltip:
                'Copy the full explanation, including every path that was '
                'searched — that list is what a bug report needs.',
          ),
          const SizedBox(width: AbSpace.xs),
          ToolbarButton(
            icon: abIcon('arrow.clockwise'),
            label: 'Look again',
            tooltip:
                'Search for abctl again and re-check the connection. Use it '
                'after dropping the binary beside the app; a change to '
                '\$ABGUI_ABCTL needs a relaunch, because the environment is '
                'read once at process start.',
            onPressed: () => unawaited(_recheck(ref)),
          ),
        ],
      ),
    );
  }

  /// The banner's own sentence, in one line.
  ///
  /// [AbctlMissingBinary.message] is a paragraph plus a path list — right for a copied bug report
  /// and wrong for a strip that clips at two lines. The `$ABGUI_ABCTL` detail is preferred when
  /// there is one, because a developer who typo'd their override needs to hear about the override
  /// and not about the app bundle they were deliberately bypassing.
  static String _oneLine(AbctlMissingBinary missing) {
    final String? detail = missing.detail;
    if (detail != null) return detail.replaceAll('\n', ' ');
    final int searched = missing.searched.length;
    return 'The command-line tool that ships inside this app is not where the app expects it. '
        'Reinstalling is the fix; a developer can set \$ABGUI_ABCTL to a locally built abctl. '
        '$searched ${searched == 1 ? 'path was' : 'paths were'} searched.';
  }

  /// Re-resolve, then re-check.
  ///
  /// Invalidating the binary provider rebuilds the runner and the clients under it, so a binary
  /// that has just appeared is picked up without a relaunch. The connection check follows because
  /// otherwise the status bar keeps saying "abctl unavailable" over a working install, and a
  /// button that fixes the problem while leaving the evidence of it on screen reads as a button
  /// that did nothing.
  static Future<void> _recheck(WidgetRef ref) async {
    ref.invalidate(abctlBinaryProvider);
    await ref.read(connectionProvider.notifier).check();
  }
}
