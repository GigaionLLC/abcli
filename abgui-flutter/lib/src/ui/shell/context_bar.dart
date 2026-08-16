// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/models/contract.dart';
import 'package:abgui/src/platform/reveal_in_file_manager.dart';
import 'package:abgui/src/state/connection_store.dart';
import 'package:abgui/src/state/gitops_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// The top strip: which tenant, which folder, and which side counts as the desired state.
///
/// **Why these three, together, at the top.** Every button in this app means something different
/// depending on all three of them — `diff` plans a different tree from a different folder against
/// a different tenant, and reverses direction on the third. The Swift app put them in a sidebar
/// FOOTER, which put the facts as far from the controls as the window allows and (because the
/// footer's height was data-driven) made them the thing that blanked the sidebar whenever a
/// command ran. This strip is the replacement, and it is deliberately NOT that footer: fixed
/// height, no last-command line — the command that is running lives in the run strip, next to its
/// elapsed time and its Cancel button, where it can change size without disturbing anything.
///
/// It runs no abctl command of its own. Reconnect and a context switch are the two exceptions and
/// both are explicit user actions; nothing here fires a command from `build`.
class ContextBar extends ConsumerWidget {
  const ContextBar({super.key, this.leading});

  /// The sidebar's collapse control, supplied by `RootShell`. Passed in rather than built here so
  /// this widget knows nothing about the sidebar's state — it just reserves the slot above it.
  final Widget? leading;

  static const double height = 34;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border(bottom: BorderSide(color: ab.line)),
      ),
      child: SizedBox(
        height: height,
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[
              const SizedBox(width: AbSpace.xs),
              leading!,
            ],
            const _Separator(),
            const _ContextChip(),
            const _Separator(),
            // The one elastic item: a workspace path is the only fact here that can be 200
            // characters long, so it is the one that gives way when the window narrows.
            const Flexible(child: _WorkspaceField()),
            const _Separator(),
            const _GitSourceOfTruthIndicator(),
            const Spacer(),
            ToolbarButton(
              icon: abIcon('arrow.clockwise'),
              label: 'Reconnect',
              tooltip:
                  'Re-run abctl version and whoami against the active context',
              onPressed: () =>
                  unawaited(ref.read(connectionProvider.notifier).check()),
            ),
            const SizedBox(width: AbSpace.xs),
          ],
        ),
      ),
    );
  }
}

/// The active tenant: a state dot, the context name, and a menu of the connections abctl already
/// told us about.
///
/// The dot and the name are ONE control because they answer one question. `whoami` failing while
/// `version` succeeded is drift, not danger: abctl runs, the tenant is simply not authenticated
/// yet, and painting that red sends a first-time user hunting for a bug instead of to Settings —
/// the exact distinction `ConnectionConnected.identity` exists to preserve.
class _ContextChip extends ConsumerWidget {
  const _ContextChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Connection connection = ref.watch(connectionProvider);
    final String active = ref.watch(activeContextProvider);
    // Watched, never LOADED from here: `abctl context list` is Settings' call to make. A menu
    // that fetched on open would run a command from a hover, and the list it fetched would arrive
    // after the menu had already built its items.
    final List<String> saved = ref.watch(
      settingsProvider.select((Settings s) => s.contexts),
    );

    final AbSeverity tone = switch (connection) {
      ConnectionConnected(:final WhoamiResult? identity) =>
        (identity?.authenticated ?? false) ? AbSeverity.ok : AbSeverity.drift,
      ConnectionFailed() => AbSeverity.danger,
      _ => AbSeverity.neutral,
    };

    return Tooltip(
      message:
          '${_summary(connection)}\nClick to scope abgui to a saved '
          'connection. This changes the --context abgui passes; it never '
          'writes abctl’s own context store.',
      child: PopupMenuButton<String>(
        tooltip: '',
        position: PopupMenuPosition.under,
        onSelected: (String name) =>
            unawaited(ref.read(connectionProvider.notifier).useContext(name)),
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          // Empty is a real choice, not a missing value: it means "whatever abctl's own current
          // context is", and it is the default this app ships with.
          const PopupMenuItem<String>(
            value: '',
            child: Text('abctl’s current context'),
          ),
          if (saved.isEmpty)
            const PopupMenuItem<String>(
              enabled: false,
              child: Text('No saved connections read yet — open Settings'),
            )
          else ...<PopupMenuEntry<String>>[
            const PopupMenuDivider(),
            for (final String name in saved)
              PopupMenuItem<String>(value: name, child: Text(name)),
          ],
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AbSpace.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: tone.ink(ab),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: MonoText(
                  active.isEmpty ? 'default context' : active,
                  size: 11.5,
                  color: ab.text,
                ),
              ),
              Icon(abIcon('chevron.down'), size: 13, color: ab.faint),
            ],
          ),
        ),
      ),
    );
  }

  /// The Swift footer's summary line, verbatim in meaning: what abctl answered, and who it says
  /// we are.
  static String _summary(Connection connection) => switch (connection) {
    ConnectionUnknown() => 'not checked',
    ConnectionChecking() => 'checking…',
    ConnectionConnected(
      :final VersionInfo version,
      :final WhoamiResult? identity,
    ) =>
      identity == null
          ? 'abctl ${version.version} · no tenant'
          : 'abctl ${version.version} · ${identity.clientID}',
    ConnectionFailed(:final String message) => message,
  };
}

/// The GitOps workspace: the folder that CONTAINS `gitops/`.
///
/// Shown as its leaf name with the full path in the tooltip. The whole path would eat the strip
/// on any real machine, and the leaf is what an operator recognizes — but the tooltip has to
/// carry the rest, because "which of my four clones is this?" is a question two folders named
/// `gitops` cannot answer on their own.
class _WorkspaceField extends ConsumerWidget {
  const _WorkspaceField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final String? workspace = ref.watch(workspaceProvider);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(width: AbSpace.sm),
        Icon(
          abIcon(workspace == null ? 'folder.badge.questionmark' : 'folder'),
          size: 14,
          color: workspace == null ? ab.faint : ab.dim,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Tooltip(
            message: workspace ?? 'No GitOps workspace chosen',
            child: MonoText(
              workspace == null ? 'no workspace' : _leaf(workspace),
              size: 11.5,
              color: workspace == null ? ab.faint : ab.text,
            ),
          ),
        ),
        const SizedBox(width: AbSpace.xs),
        ToolbarButton(
          icon: abIcon('folder.badge.plus'),
          label: 'Choose workspace',
          tooltip:
              'Choose the folder that contains gitops/ — every abctl command '
              'abgui runs uses it as its working directory',
          onPressed: () => unawaited(_choose(ref)),
        ),
        if (workspace != null)
          ToolbarButton(
            // "Show me", not "search": a magnifying glass here would read as a filter over the
            // path, which is the one thing this button does not do.
            icon: abIcon('eye'),
            label: 'Reveal workspace',
            tooltip: 'Show this folder in the system file manager',
            onPressed: () => unawaited(RevealInFileManager.reveal(workspace)),
          ),
      ],
    );
  }

  /// Pick a folder and point every command at it.
  ///
  /// The notifier is captured BEFORE the await. The picker is a native dialog that can sit open
  /// for minutes, and reaching back through `ref` afterwards would be reaching through a widget
  /// that may well be gone.
  static Future<void> _choose(WidgetRef ref) async {
    final GitopsStore gitops = ref.read(gitopsProvider.notifier);
    final String? current = ref.read(workspaceProvider);
    final String? chosen = await getDirectoryPath(
      initialDirectory: current,
      confirmButtonText: 'Choose',
    );
    if (chosen == null) return; // cancelled — not an error, and nothing to say
    await gitops.setWorkspace(chosen);
  }

  /// The last path segment, without importing `path` or touching `dart:io`. Both separators are
  /// checked because a Windows user's path can carry either, and a trailing one is trimmed first
  /// so `C:\repos\tenant\` is `tenant` rather than the empty string.
  static String _leaf(String path) {
    var end = path.length;
    while (end > 0 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
      end--;
    }
    if (end == 0) return path;
    var start = end - 1;
    while (start > 0 && path[start - 1] != '/' && path[start - 1] != r'\') {
      start--;
    }
    return path.substring(start, end);
  }
}

/// Which side `diff` treats as the desired state.
///
/// **An indicator, not a switch.** In the Swift app this control gated deletes — turning it ON
/// authorized `sync --apply` to remove Apple-only configurations — so it was a button behind a
/// confirmation dialog. This build ships no apply, so the flag only reverses which side of the
/// comparison counts as desired, and the one screen that spends it (Diff) is where it should be
/// changed: flipping it DROPS the computed plan, and a plan vanishing because someone clicked a
/// chip in the window chrome is a worse surprise than walking to the screen that owns it.
///
/// The WORD is the indicator; the padlock and the tint reinforce it. That rule is inherited
/// verbatim from `GitSourceOfTruthControl` and is why this reads correctly in a screenshot.
class _GitSourceOfTruthIndicator extends ConsumerWidget {
  const _GitSourceOfTruthIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final bool enabled = ref.watch(
      gitopsProvider.select((GitopsState s) => s.gitSourceOfTruth),
    );
    return Tooltip(
      message: enabled
          ? 'ON — gitops/ is the complete desired state: configurations that '
                'exist only in Apple Business are planned as deletes. This '
                'build never applies a plan. Change it on the Diff screen.'
          : 'OFF — additive, newest-wins: configurations that exist only in '
                'Apple Business are planned INTO gitops/ and nothing is '
                'planned for removal. Change it on the Diff screen.',
      child: Semantics(
        label: 'Git source of truth',
        value: enabled ? 'on' : 'off',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AbSpace.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                abIcon(enabled ? 'lock.fill' : 'arrow.left.arrow.right'),
                size: 14,
                color: enabled ? ab.ok : ab.dim,
              ),
              const SizedBox(width: 6),
              Text('git', style: TextStyle(fontSize: 11.5, color: ab.dim)),
              const SizedBox(width: 6),
              AbBadge(
                label: enabled ? 'ON' : 'OFF',
                severity: enabled ? AbSeverity.ok : AbSeverity.neutral,
                fontSize: 10,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A hairline between two facts. The strip holds three unrelated things; without rules they read
/// as one run-on sentence.
class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    return Container(
      width: 1,
      height: ContextBar.height - AbSpace.md,
      color: ab.line,
      margin: const EdgeInsets.symmetric(horizontal: AbSpace.xs),
    );
  }
}
