// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';

/// What a pane shows instead of nothing.
///
/// An empty table and a broken table look identical when both render as blank space, and that
/// ambiguity cost real support time on the Swift app: "the Devices screen is empty" turned out
/// to mean three different things (no devices, a filter that matched nothing, and an expired
/// token). So every empty pane must SAY which one it is — the title names the situation, and
/// [message] carries the detail that makes it actionable.
///
/// This is a plain presentational widget with no state of its own: `AbTable` decides which of
/// the three cases it is in and renders one of these, so no screen re-implements the choice.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.tone = AbSeverity.neutral,
    this.action,
  });

  final String title;

  /// The sentence that turns "nothing here" into something the user can act on: what was
  /// filtered out, which command failed, what to try.
  final String? message;

  final IconData icon;

  /// [AbSeverity.danger] for the load-failed case. Neutral for a genuinely empty result — an
  /// organization with no packages is not an error and must not be dressed as one.
  final AbSeverity tone;

  /// Optional single control (Retry, Clear filter). Kept to one: an empty pane offering four
  /// buttons is a menu, not an explanation.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final detail = message;
    return Semantics(
      // The pane is announced as one thing. Without this, VoiceOver walks an icon, a heading and
      // a paragraph as three unrelated stops and the user has to assemble the meaning.
      container: true,
      label: detail == null ? title : '$title. $detail',
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AbSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Only the prose is excluded — the label above already speaks it, and leaving it
              // in would have VoiceOver read the whole state twice. [action] stays OUTSIDE this
              // wrapper: excluding a Retry button would make the one control on an error pane
              // unreachable by keyboard-and-screen-reader users.
              ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      icon,
                      size: 28,
                      color: tone.ink(ab).withValues(alpha: 0.8),
                    ),
                    const SizedBox(height: AbSpace.md),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: tone == AbSeverity.neutral
                            ? ab.dim
                            : tone.ink(ab),
                      ),
                    ),
                    if (detail != null) ...<Widget>[
                      const SizedBox(height: AbSpace.sm),
                      ConstrainedBox(
                        // Long Apple error bodies land here. Capping the measure keeps them
                        // readable instead of stretching one sentence across a 1600px pane.
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Text(
                          detail,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: ab.faint,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: AbSpace.lg),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
