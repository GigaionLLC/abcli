// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/services.dart';

/// The one place abgui writes to the system clipboard.
///
/// It exists for three reasons, none of them wrapping-for-the-sake-of-it:
///
/// 1. **It cannot throw into a button.** `Clipboard.setData` is a platform-channel call and
///    channel calls fail: a Linux session with no clipboard owner, a remote/headless desktop, a
///    Windows `OpenClipboard` losing the race to one of the clipboard-manager utilities half
///    the fleet runs. Awaited from an `onPressed` that returns void, that failure lands in
///    Flutter's error zone as a red screen or a silent zone-error, over a copy button. [copy]
///    answers `false` instead, so the affordance can stay quiet or say "couldn't copy" — the
///    text it was copying is on screen and selectable in every one of these placements anyway.
///
/// 2. **It refuses to copy nothing.** Setting empty text does not fail; it replaces the
///    clipboard with an empty string. A "Copy transcript" pressed on a run that has not printed
///    anything yet would therefore destroy whatever the user had copied a minute ago, with no
///    undo and no signal. Empty in, `false` out, clipboard untouched.
///
/// 3. **One confirmation timing.** The Swift `CopyButton` flashed a checkmark for 1.5s; every
///    copy affordance in this app reads that constant from here rather than picking its own, so
///    two adjacent buttons cannot disagree about how long "Copied" lasts.
///
/// One thing NOT ported: the Swift version's `NSPasteboard.clearContents()`. That call was
/// mandatory on AppKit, where `setString` ADDS a representation and a paste could come back as
/// the previous copy. Flutter's `setData` replaces the board outright on all three desktops, so
/// there is nothing to clear — do not reintroduce it as a "safety" call, there is no API for it.
abstract final class AbClipboard {
  /// How long a copy affordance shows its confirmed state. Long enough to be seen after the
  /// eye has moved on, short enough that the button is back to its normal label before a user
  /// wonders whether a second click would do anything.
  static const Duration confirmationDuration = Duration(milliseconds: 1500);

  /// Put [text] on the clipboard. Returns whether the platform accepted it.
  ///
  /// `true` means the channel call completed, not that a later paste will succeed — no desktop
  /// clipboard API offers that guarantee, and pretending otherwise would put a claim in the UI
  /// that nothing can back up.
  static Future<bool> copy(String text) async {
    // See reason 2 above: an empty copy is a clipboard wipe with a friendly label on it.
    if (text.isEmpty) return false;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      // PlatformException, MissingPluginException, a channel that never answers — all of them
      // mean "the text is not on the clipboard", which is the only thing a caller can act on.
      return false;
    }
  }
}
