// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/theme.dart';

/// How much width a toolbar control earns.
///
/// Ported verbatim in spirit from the Swift `ToolbarWeight`, including the finding that produced
/// it: labelling every control outgrew the window (at ~1090px the last item was clipped with no
/// overflow affordance), and labelling none of them left a row of anonymous glyphs. Width is
/// finite, so a word is spent only where it resolves an ambiguity a glyph cannot.
enum AbToolbarWeight {
  /// Title + icon. For the control whose consequence must not be misread.
  titled,

  /// Icon + tooltip. For glyphs that are universally understood — refresh, folder, export.
  compact,
}

/// A toolbar control.
///
/// [tooltip] is REQUIRED and never optional, for the same reason it was in Swift: a compact
/// control is an icon and nothing else, and an icon with no hover text is unidentifiable by any
/// means at all. Write it to name the CONSEQUENCE, not the mechanism — "Re-fetch this inventory
/// from Apple Business", not "Refresh". The same glyph means different things on different
/// screens, and the tooltip is the only place that difference is stated.
class ToolbarButton extends StatelessWidget {
  const ToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onPressed,
    this.weight = AbToolbarWeight.compact,
    this.selected = false,
  });

  final IconData icon;

  /// The control's name. Shown when [weight] is titled, and always used as the accessibility
  /// label — so a compact control is still named for a screen reader.
  final String label;

  final String tooltip;

  /// Null disables the control. Disabled is a real state here: several controls need exactly
  /// one selected row, and a button that is present but inert says "this exists, you are not
  /// eligible yet" where a hidden button says nothing.
  final VoidCallback? onPressed;

  final AbToolbarWeight weight;

  /// For toggles (density, a sticky filter). Drawn sunken, because a toggle that only changes
  /// tint is indistinguishable from a hover state on this palette.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final enabled = onPressed != null;
    final ink = enabled ? (selected ? ab.accent : ab.dim) : ab.faint;
    final showTitle = weight == AbToolbarWeight.titled;

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        // The visuals below are decoration for this label; letting them through would have
        // VoiceOver announce the icon glyph and the title as separate stops.
        excludeSemantics: true,
        child: Material(
          color: selected ? ab.sunken : Colors.transparent,
          borderRadius: BorderRadius.circular(AbSpace.radius),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(AbSpace.radius),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: showTitle ? AbSpace.sm : 6,
                vertical: 5,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(icon, size: 15, color: ink),
                  if (showTitle) ...<Widget>[
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: ink,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
