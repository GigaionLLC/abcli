// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:abgui/src/platform/clipboard.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// What the button is currently saying. `failed` is a real state, not defensive padding:
/// `AbClipboard.copy` answers false on a headless session, on a Linux desktop with no clipboard
/// owner, and whenever a clipboard manager wins the race for the Windows board — and a copy
/// affordance that silently does nothing in those cases is how a user comes to believe the app
/// is broken.
enum _CopyOutcome { idle, copied, failed }

/// The one copy affordance in the app.
///
/// It started life beside the diagnostic screens (`screens/diagnostics_chrome.dart`) and was
/// promoted here the moment a second family — the GitOps plan transcript, the validate report's
/// external-validator output, the raw profile XML — needed the same control, exactly as that
/// file's own rule says to. `diagnostics_chrome.dart` re-exports it, so nothing over there had to
/// change; a second copy button would have been the drift `AbClipboard` centralises the
/// confirmation constant to prevent.
///
/// Clicking flips it to a checkmark for [AbClipboard.confirmationDuration]: without that a copy
/// button gives no evidence it did anything, which is the Swift `CommandCopyButton`'s finding and
/// the reason that timing lives on `AbClipboard` rather than here.
class CopyButton extends StatefulWidget {
  const CopyButton({
    super.key,
    required this.text,
    required this.tooltip,
    this.label = 'Copy',
    this.weight = AbToolbarWeight.compact,
    this.enabled = true,
  });

  /// Built when the button is PRESSED, never on every rebuild.
  ///
  /// A tear-off rather than a `String` because of two specific call sites: the Command Log's
  /// "Copy all as script" concatenates every recorded command, and the GitOps progress strip sits
  /// beside a transcript republished every 100 ms while a plan runs. Evaluating either eagerly
  /// would rebuild the whole string on each render of a pane nobody has clicked. (Swift solved it
  /// with `@autoclosure @escaping`; this is the same trick with Dart spelling.)
  final String Function() text;

  final String tooltip;
  final String label;
  final AbToolbarWeight weight;

  /// False disables the control — for "there is nothing to copy yet", which must look different
  /// from a button that works and silently copies an empty string over the user's clipboard.
  final bool enabled;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  _CopyOutcome _outcome = _CopyOutcome.idle;
  Timer? _reset;

  @override
  void dispose() {
    // A pending confirmation outlives the widget when a screen is left immediately after a copy;
    // the timer would then call setState on a dead element.
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final bool ok = await AbClipboard.copy(widget.text());
    if (!mounted) return;
    setState(() => _outcome = ok ? _CopyOutcome.copied : _CopyOutcome.failed);
    _reset?.cancel();
    _reset = Timer(AbClipboard.confirmationDuration, () {
      if (mounted) setState(() => _outcome = _CopyOutcome.idle);
    });
  }

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String label) = switch (_outcome) {
      _CopyOutcome.idle => (abIcon('doc.on.doc'), widget.label),
      _CopyOutcome.copied => (abIcon('checkmark'), 'Copied'),
      _CopyOutcome.failed => (abIcon('xmark'), 'Couldn\'t copy'),
    };
    return ToolbarButton(
      icon: icon,
      label: label,
      // The tooltip becomes the outcome while the confirmation is showing, because on a compact
      // (icon-only) button the glyph is the whole message and a stale "Copy this command" would
      // contradict it.
      tooltip: _outcome == _CopyOutcome.failed
          ? 'The system clipboard refused the copy. The text is on screen and selectable.'
          : (_outcome == _CopyOutcome.copied ? 'Copied.' : widget.tooltip),
      weight: widget.weight,
      selected: _outcome == _CopyOutcome.copied,
      onPressed: widget.enabled ? () => unawaited(_copy()) : null,
    );
  }
}
