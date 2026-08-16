// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';

/// One option in a mutually-exclusive choice, drawn as a row that states its own consequence.
///
/// **Why the write dialogs use this instead of a segmented picker.** A segmented control is for a
/// cheap, frequently-changed scoping choice — the audit window, the OS-release catalog — where the
/// options differ only in degree and the cost of picking the wrong one is one wasted read. The
/// choices here are not that: attach and detach change a live tenant in opposite directions, and
/// `adopt` does not touch the tenant at all. Three words in three segments would flatten exactly
/// the distinction the operator has to notice, and there would be nowhere to say what each one
/// does. So each option gets a line of consequence and a [scope] badge naming WHERE it writes.
///
/// [scope] is the half that cannot be inferred from the verb. "Apple Business" and "git only" are
/// the two answers that matter in this app, and confusing them is the specific mistake that
/// produced the drift row an operator could not clear.
class AbChoiceCard extends StatelessWidget {
  const AbChoiceCard({
    super.key,
    required this.title,
    required this.detail,
    required this.icon,
    required this.selected,
    required this.onSelected,
    required this.scope,
    this.scopeSeverity = AbSeverity.neutral,
    this.enabled = true,
  });

  final String title;

  /// What choosing this DOES, in one or two sentences — the tenant effect first, the local effect
  /// second. This is the text that has to survive being read in a hurry.
  final String detail;

  final IconData icon;
  final bool selected;

  /// Null-safe by construction: [enabled] false renders the card inert rather than hiding it, so
  /// an option that exists but is not available right now still says so.
  final VoidCallback onSelected;

  /// Where this option writes: 'Apple Business', 'git only'. Shown as a pill.
  final String scope;

  /// The pill's colour. [AbSeverity.danger] for the options that remove something.
  final AbSeverity scopeSeverity;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final Color ink = enabled ? ab.text : ab.faint;
    final Color edge = selected ? ab.accent : ab.line;

    return Semantics(
      // A radio, not a button: this announces "1 of 3, selected" rather than leaving a screen
      // reader to guess that picking one un-picks the others.
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      label: '$title. $detail Writes to $scope.',
      excludeSemantics: true,
      child: Material(
        color: selected ? ab.sunken : ab.surface,
        borderRadius: BorderRadius.circular(AbSpace.radius),
        child: InkWell(
          onTap: enabled ? onSelected : null,
          borderRadius: BorderRadius.circular(AbSpace.radius),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: edge, width: selected ? 1.5 : 1),
              borderRadius: BorderRadius.circular(AbSpace.radius),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: AbSpace.md,
              vertical: AbSpace.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    icon,
                    size: 16,
                    color: enabled ? (selected ? ab.accent : ab.dim) : ab.faint,
                  ),
                ),
                const SizedBox(width: AbSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.35,
                          color: enabled ? ab.dim : ab.faint,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AbSpace.sm),
                AbBadge(label: scope, severity: scopeSeverity),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
