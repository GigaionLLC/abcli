// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';

/// What a value is DOING, on the four-level scale the palette already encodes.
///
/// This lives here, next to the pill, rather than in `theme.dart`: the pill is the canonical
/// rendering of a severity, and every other consumer (the table's row stripe, the notice
/// banner, the empty state) is a variation on it. Putting the enum anywhere else would mean
/// three widgets each writing their own severity-to-colour switch, which is exactly the
/// "what does drift look like?" problem `AbColors`'s doc comment was written about — the Swift
/// app answered it differently in a dozen views.
enum AbSeverity {
  /// No claim. Renders in the neutral chrome colours, NOT in green: a badge whose state we do
  /// not know must not read as "fine".
  neutral,
  ok,
  drift,
  danger,
}

/// The one severity-to-colour mapping in the app.
extension AbSeverityPalette on AbSeverity {
  /// Text and glyph colour.
  Color ink(AbColors ab) => switch (this) {
    AbSeverity.neutral => ab.dim,
    AbSeverity.ok => ab.ok,
    AbSeverity.drift => ab.drift,
    AbSeverity.danger => ab.danger,
  };

  /// Fill behind [ink]. The `*Bg` pairs are contrast-checked against their ink in both themes;
  /// never compose a background by fading the ink instead.
  Color ground(AbColors ab) => switch (this) {
    AbSeverity.neutral => ab.raised,
    AbSeverity.ok => ab.okBg,
    AbSeverity.drift => ab.driftBg,
    AbSeverity.danger => ab.dangerBg,
  };

  /// Border colour. Neutral borrows the structural hairline so a stateless pill reads as chrome;
  /// the rest use their own ink held back, which keeps the pill's EDGE legible on the coloured
  /// ground without the outline shouting louder than the word inside it.
  Color edge(AbColors ab) =>
      this == AbSeverity.neutral ? ab.line : ink(ab).withValues(alpha: 0.55);

  /// What a screen reader should say when the colour is the only thing carrying the state.
  /// Deliberately plain words, not the enum names: "drift" is our jargon.
  String get spokenName => switch (this) {
    AbSeverity.neutral => 'no state',
    AbSeverity.ok => 'ok',
    AbSeverity.drift => 'needs attention',
    AbSeverity.danger => 'failed',
  };
}

/// A bordered pill: the app's one way of showing a short state word.
///
/// Bordered rather than filled-only on purpose. A fill alone encodes state in colour only, and
/// this app is read by people auditing thousands of rows — the outline gives the pill a SHAPE,
/// so a badge is still identifiable as a badge (and distinguishable from a plain cell) with no
/// colour vision at all. The label itself always carries the meaning in words; the colour is
/// redundant reinforcement, never the sole channel.
class AbBadge extends StatelessWidget {
  const AbBadge({
    super.key,
    required this.label,
    this.severity = AbSeverity.neutral,
    this.highlight = '',
    this.fontSize,
  });

  final String label;
  final AbSeverity severity;

  /// The active table filter. Matching runs of the label are highlighted so a row that survived
  /// a search because of its STATE shows why, the same as any other cell.
  final String highlight;

  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: severity.ground(ab),
        border: Border.all(color: severity.edge(ab)),
        // A full capsule, not the app's 3px radius: the pill has to read as a different KIND of
        // object from the panels and buttons around it, and roundness is the cheapest signal.
        borderRadius: BorderRadius.circular(999),
      ),
      child: MonoText(
        label,
        highlight: highlight,
        size: fontSize ?? 11,
        color: severity.ink(ab),
        weight: FontWeight.w600,
      ),
    );
  }
}
