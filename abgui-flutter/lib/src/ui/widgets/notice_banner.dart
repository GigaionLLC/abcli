// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/badge.dart';

/// A full-width strip above a pane's content that states a standing fact about it.
///
/// Two jobs, both ported from the Swift app:
///
///  * the read-only disclosure every browse screen carries (`ReadOnlyListView.banner`), and
///  * the one it did NOT have and should have: a refresh failed while rows from the last good
///    load are still on screen. Swift only ever showed an error when the list was EMPTY, so a
///    stale table looked exactly like a fresh one and the user had no way to know the numbers
///    they were reading were from ten minutes ago.
///
/// It is a strip rather than a dialog because it must not interrupt: none of these facts stop
/// the user from reading the rows underneath.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    super.key,
    required this.text,
    this.detail,
    this.icon,
    this.tone = AbSeverity.neutral,
    this.trailing,
  });

  /// The headline, in the user's terms. Says what is true, not what happened internally.
  final String text;

  /// The supporting clause after the separator dot — the note that explains WHY.
  final String? detail;

  final IconData? icon;
  final AbSeverity tone;

  /// An optional control on the right (Retry, Dismiss). Never required: the banner has to be
  /// readable as pure information.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final ink = tone.ink(ab);
    final note = detail;
    return Semantics(
      container: true,
      liveRegion: tone != AbSeverity.neutral,
      label: note == null ? text : '$text. $note',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AbSpace.lg,
          vertical: AbSpace.sm,
        ),
        decoration: BoxDecoration(
          color: tone.ground(ab),
          border: Border(bottom: BorderSide(color: ab.line)),
        ),
        child: Row(
          children: <Widget>[
            // The wording is already in the Semantics label above; excluding it here stops the
            // banner being read twice. [trailing] is deliberately NOT inside this exclusion —
            // it holds the Retry/Dismiss control, and an unreachable control is worse than a
            // repeated sentence.
            ExcludeSemantics(
              child: icon == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(right: AbSpace.sm),
                      child: Icon(icon, size: 13, color: ink),
                    ),
            ),
            Flexible(
              child: ExcludeSemantics(
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: text,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: ink,
                        ),
                      ),
                      if (note != null)
                        TextSpan(
                          text: '  ·  $note',
                          style: TextStyle(fontSize: 12, color: ab.dim),
                        ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: AbSpace.md),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A tinted, rounded paragraph that qualifies the thing above it.
///
/// **One widget where there were three, and the drift had already started.** The four write
/// dialogs were built in parallel and each grew its own version: `assign_dialog._sentence` and
/// `membership_dialog._sentence` were byte-identical, while `apply_dialog._Note` and
/// `config_editor_dialog._Note` were two DIFFERENT widgets sharing one name — same tint, same
/// radius, different ink, different text widget, different constructor signature. A reader moving
/// between two write dialogs was reading two things that looked alike and were not, which on this
/// set of screens is exactly the wrong kind of surprise.
///
/// Distinct from [NoticeBanner], which is the full-width strip a PANE carries: this is an inline
/// block inside a dialog's body, so it is rounded and bordered rather than edge-to-edge, and it
/// sits with the sentence it qualifies rather than above the whole screen.
///
/// [selectable] is on by default because most callers are explaining a failure, and a failure a
/// user cannot select is a failure they retype into a ticket by hand. [icon] is optional: the
/// glyph earns its place when the note is a standing rule (a padlock beside "git is the source of
/// truth"), and gets in the way when the note is one sentence of prose.
class AbNote extends StatelessWidget {
  const AbNote({
    super.key,
    required this.text,
    this.tone = AbSeverity.neutral,
    this.icon,
    this.selectable = true,
  });

  final String text;
  final AbSeverity tone;
  final IconData? icon;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    // Neutral has no ink of its own worth reading a paragraph in — `tone.ink` for it is the same
    // grey the label above uses — so plain body text wins there and the tinted ink is reserved
    // for the tones that MEAN something.
    final Color ink = tone == AbSeverity.neutral ? ab.text : tone.ink(ab);
    final Widget body = selectable
        ? SelectableText(
            text,
            style: TextStyle(fontSize: 11.5, height: 1.4, color: ink),
          )
        : Text(text, style: TextStyle(fontSize: 11.5, height: 1.4, color: ink));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AbSpace.sm),
      decoration: BoxDecoration(
        color: tone.ground(ab),
        border: Border.all(color: tone.edge(ab)),
        borderRadius: BorderRadius.circular(AbSpace.radius),
      ),
      child: Semantics(
        // A note that has just replaced an outcome is the thing a screen reader must be told
        // about; a standing rule that has been there since the sheet opened is not.
        liveRegion: tone != AbSeverity.neutral,
        child: icon == null
            ? body
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(icon, size: 14, color: ink),
                  const SizedBox(width: AbSpace.sm),
                  Expanded(child: body),
                ],
              ),
      ),
    );
  }
}
