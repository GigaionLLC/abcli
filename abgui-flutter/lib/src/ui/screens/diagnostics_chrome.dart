// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/platform/clipboard.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/copy_button.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

// `CopyButton` was defined in this file until the GitOps screens — a second family — needed the
// same control, at which point the rule stated below said promote it rather than copy it. It now
// lives in `ui/widgets/copy_button.dart`, and is re-exported here so that every screen already
// importing this chrome keeps referring to it unchanged.
export 'package:abgui/src/ui/widgets/copy_button.dart' show CopyButton;

/// The chrome the five DIAGNOSTIC screens share: the page frame, the copy affordance, the
/// key/value row and the filter box.
///
/// **Why it lives beside the screens rather than in `ui/widgets/`.** Everything in `widgets/` is
/// consumed by the whole app (the table, the badge, the banner). These four are consumed by
/// exactly one family — Command Log, Logs, Console, Settings, System Health — and they encode
/// that family's conventions rather than the app's: a header bar with a right-aligned tool row, a
/// copy button that confirms for [AbClipboard.confirmationDuration], a label column wide enough
/// for "Working directory". Promote a piece the moment a second family needs it; do NOT copy one,
/// because two copy buttons that disagree about how long "Copied" lasts is precisely the drift
/// `AbClipboard` centralises the constant to prevent.
///
/// Nothing here owns state that outlives a frame, and nothing here reaches abctl.

/// The page frame every diagnostic screen is built in.
///
/// It is deliberately NOT a `Scaffold`: these screens are placed inside the app shell's detail
/// pane, and a nested Scaffold would give each one its own Material layer, its own background and
/// its own floating-action/snackbar surface — three things the shell already owns. What a screen
/// genuinely needs is a title, somewhere for its tools to sit, and a bounded body it can put an
/// `AbTable` in; that is all this provides.
class ScreenScaffold extends StatelessWidget {
  const ScreenScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const <Widget>[],
    this.banner,
  });

  /// The screen's name, as the sidebar spells it.
  final String title;

  /// The one quiet fact that belongs next to the title — a count, a directory, the active
  /// tenant. Truncated rather than wrapped: the header is a fixed-height strip, and a subtitle
  /// that reflows would move every tool on the row.
  final String? subtitle;

  /// Tools, right-aligned. Usually [CopyButton]s and [ToolbarButton]s.
  final List<Widget> actions;

  /// A `NoticeBanner` for a standing fact about the whole screen (abgui never writes the
  /// credential store; the log directory could not be created). Sits UNDER the header so it
  /// cannot be scrolled away from the thing it qualifies.
  final Widget? banner;

  /// The body. Given a bounded height, so it may contain an `AbTable`.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final caption = subtitle;
    return ColoredBox(
      color: ab.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: AbSpace.lg),
            decoration: BoxDecoration(
              color: ab.raised,
              border: Border(bottom: BorderSide(color: ab.line)),
            ),
            child: Row(
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ab.text,
                    ),
                  ),
                ),
                if (caption != null && caption.isNotEmpty) ...<Widget>[
                  const SizedBox(width: AbSpace.md),
                  Flexible(
                    child: Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AbType.mono(context, size: 11, color: ab.faint),
                    ),
                  ),
                ],
                const Spacer(),
                for (final Widget action in actions) ...<Widget>[
                  const SizedBox(width: AbSpace.xs),
                  action,
                ],
              ],
            ),
          ),
          if (banner != null) banner!,
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A titled panel inside a screen body: a label, then a bordered surface holding the rows.
///
/// Used by Settings and System Health, which are forms rather than tables. The border is what
/// makes a group of key/value rows read as one answer instead of as eight loose lines.
class ScreenSection extends StatelessWidget {
  const ScreenSection({
    super.key,
    required this.title,
    required this.children,
    this.note,
    this.trailing,
  });

  final String title;

  /// The sentence under the panel that says what the reader is looking at, or what they cannot
  /// do here. This is where the read-only boundary gets stated per section rather than once in a
  /// banner nobody re-reads.
  final String? note;

  /// A control belonging to the section as a whole (Recheck, Refresh).
  final Widget? trailing;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final footnote = note;
    return Padding(
      padding: const EdgeInsets.only(bottom: AbSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(title.toUpperCase(), style: AbType.label(context)),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AbSpace.sm),
          DecoratedBox(
            decoration: BoxDecoration(
              color: ab.surface,
              border: Border.all(color: ab.line),
              borderRadius: BorderRadius.circular(AbSpace.radius),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AbSpace.md,
                vertical: AbSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
          if (footnote != null) ...<Widget>[
            const SizedBox(height: AbSpace.xs),
            Text(
              footnote,
              style: TextStyle(fontSize: 11, color: ab.faint, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

/// One `label: value` line, with the value selectable and a copy button beside it.
///
/// The value is monospaced because everything these screens show in this shape is machine data —
/// a path, a version, an identifier, an OS build string. It is selectable AS WELL as copyable:
/// the button takes the whole value, selection takes the part someone actually wants.
class CopyableField extends StatelessWidget {
  const CopyableField({
    super.key,
    required this.label,
    required this.value,
    this.copyTooltip,
    this.labelWidth = 150,
    this.placeholder = '—',
  });

  final String label;

  /// Empty means "we do not know", which is rendered as [placeholder] and is NOT copyable —
  /// putting an em dash on the clipboard is a copy button lying about having worked.
  final String value;

  final String? copyTooltip;
  final double labelWidth;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final known = value.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: Padding(
              // Two pixels of optical alignment: the label is 10px and the value 12.5px, so their
              // baselines do not otherwise agree on a row whose value has wrapped.
              padding: const EdgeInsets.only(top: 3),
              child: Text(label.toUpperCase(), style: AbType.label(context)),
            ),
          ),
          Expanded(
            child: SelectableText(
              known ? value : placeholder,
              style: AbType.mono(context, color: known ? ab.text : ab.faint),
            ),
          ),
          const SizedBox(width: AbSpace.sm),
          CopyButton(
            text: () => value,
            enabled: known,
            tooltip: copyTooltip ?? 'Copy $label to the clipboard.',
            label: 'Copy $label',
          ),
        ],
      ),
    );
  }
}

/// The filter box that feeds `AbTable.filter`.
///
/// It owns its controller (a screen that owned one would have to remember to dispose it) and
/// reports every keystroke: the table's filtering is a linear scan over rows it already holds, so
/// there is nothing to debounce and a delay would only make typing feel laggy.
class ScreenSearchField extends StatefulWidget {
  const ScreenSearchField({
    super.key,
    required this.onChanged,
    this.hint = 'Filter',
    this.width = 210,
  });

  final ValueChanged<String> onChanged;
  final String hint;
  final double width;

  @override
  State<ScreenSearchField> createState() => _ScreenSearchFieldState();
}

class _ScreenSearchFieldState extends State<ScreenSearchField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return SizedBox(
      width: widget.width,
      height: 26,
      child: TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        style: AbType.mono(context, size: 12),
        cursorColor: ab.accent,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: ab.surface,
          hintText: widget.hint,
          hintStyle: AbType.mono(context, size: 12, color: ab.faint),
          prefixIcon: Icon(
            abIcon('magnifyingglass'),
            size: 14,
            color: ab.faint,
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 26),
          contentPadding: const EdgeInsets.symmetric(horizontal: AbSpace.sm),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AbSpace.radius),
            borderSide: BorderSide(color: ab.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AbSpace.radius),
            borderSide: BorderSide(color: ab.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AbSpace.radius),
            borderSide: BorderSide(color: ab.accent),
          ),
        ),
      ),
    );
  }
}

/// A block of machine text that can be read and selected: a command line, a transcript, a
/// stream of output.
///
/// Selectable rather than plain `Text` because every one of these blocks exists to be taken
/// somewhere else — a ticket, a terminal, a message to the developer — and a copy button only
/// ever offers the WHOLE thing. It wraps rather than truncating: an `abctl sync` line with a
/// dozen flags is precisely the one worth reading in full.
class SelectableMono extends StatelessWidget {
  const SelectableMono(
    this.text, {
    super.key,
    this.size,
    this.color,
    this.weight,
  });

  final String text;
  final double? size;
  final Color? color;
  final FontWeight? weight;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      text,
      style: AbType.mono(context, size: size, color: color, weight: weight),
    );
  }
}
