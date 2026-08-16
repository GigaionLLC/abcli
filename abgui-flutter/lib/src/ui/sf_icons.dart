// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

/// SF Symbol name → Material [IconData]. The whole translation table, in one file.
///
/// **Why translate at all.** The macOS original names its glyphs as SF Symbols strings, and
/// several of those strings are DATA, not view code: `ReadOnlyKind.symbol` and the sidebar's
/// `SidebarItem.symbol` return them from the model layer precisely so that layer stays free of
/// widget imports. The symbols themselves cannot come with us — the SF Symbols set is licensed
/// by Apple for use in apps on Apple platforms, so the font is not ours to redistribute inside a
/// Windows or Linux build. Material's icon font already ships with Flutter on all three. So the
/// names survive as identifiers and this file is where they become glyphs.
///
/// **Why ONE file.** Done at each call site, the same symbol resolves to `Icons.delete` in one
/// view and `Icons.delete_outline` in the next, and nothing ever notices — icons are the one
/// part of a UI where an inconsistency reads as a rendering bug rather than a mistake. The Swift
/// app had exactly this problem with colour (see the note at the top of `theme.dart`). Keeping
/// all ~90 rows adjacent also makes the table reviewable as a whole: filled/outlined pairs stay
/// paired, and "these two are the same glyph" is visible instead of inferred.
///
/// **Weight convention.** Outlined by default, filled only where the original used a `.fill`
/// variant. In SwiftUI a `.fill` symbol is a deliberate escalation — a status that has resolved,
/// a banner that wants to be noticed — so the distinction carries meaning and is preserved
/// row-for-row rather than normalized away.
///
/// Never add a mapping at a call site. Add the row here.
const Map<String, IconData> sfSymbolIcons = <String, IconData>{
  // -- Status and verdict -------------------------------------------------------------------
  // The pairs matter: succeeded/partial/failed in ApplySheet, and ok/warning/failed per profile
  // in ValidateSheet, must stay three visibly different shapes and not three tints of one.
  'checkmark': Icons.check,
  'checkmark.circle': Icons.check_circle_outline,
  'checkmark.circle.fill': Icons.check_circle,
  'checkmark.seal': Icons.verified_outlined,
  'checkmark.seal.fill': Icons.verified,
  'checkmark.shield': Icons.verified_user_outlined,
  'xmark': Icons.close,
  'xmark.circle': Icons.cancel_outlined,
  'xmark.circle.fill': Icons.cancel,
  // "nothing landed" vs. the triangle's "some of it landed" — the octagon is the only Material
  // glyph that keeps those two apart at toolbar size, which is the distinction ApplySheet's
  // comment says the symbol exists to make.
  'xmark.octagon.fill': Icons.dangerous,
  'xmark.seal': Icons.gpp_bad_outlined,
  'exclamationmark.circle': Icons.error_outline,
  'exclamationmark.triangle': Icons.warning_amber_outlined,
  'exclamationmark.triangle.fill': Icons.warning,
  'info.circle': Icons.info_outline,
  'info.circle.fill': Icons.info,
  'questionmark': Icons.question_mark,
  'questionmark.circle': Icons.help_outline,
  'minus.circle': Icons.remove_circle_outline,
  // Cancelled, not failed. A red X would libel a command the user stopped on purpose.
  'slash.circle': Icons.block,
  'circle': Icons.circle_outlined,
  'circle.fill': Icons.circle,
  // Timed out. `timer_off` says "the clock ran out" where a plain warning triangle would say
  // "something is wrong", and a timeout is a specific, actionable thing in the command log.
  'clock.badge.exclamationmark': Icons.timer_off_outlined,
  // A run with no footer: the app died mid-command, so the outcome is unknown rather than bad.
  'clock.badge.questionmark': Icons.pending_outlined,
  'clock': Icons.schedule,
  // The read-only badge that sits on eight of this app's screens.
  'lock': Icons.lock_outline,
  'lock.fill': Icons.lock,
  'lock.open': Icons.lock_open,

  // -- Navigation, disclosure, sorting ------------------------------------------------------
  'chevron.up': Icons.keyboard_arrow_up,
  'chevron.down': Icons.keyboard_arrow_down,
  'chevron.left': Icons.keyboard_arrow_left,
  'chevron.right': Icons.keyboard_arrow_right,
  'chevron.up.chevron.down': Icons.unfold_more,
  'arrow.up': Icons.arrow_upward,
  'arrow.down': Icons.arrow_downward,
  // Toolbar overflow. macOS collapses a crowded toolbar for you; Flutter does not, so this is
  // needed here where the Swift views never had to name it.
  'ellipsis': Icons.more_horiz,
  'sidebar.left': Icons.view_sidebar_outlined,
  'arrow.up.left.and.arrow.down.right': Icons.open_in_full,
  'arrow.down.right.and.arrow.up.left': Icons.close_fullscreen,
  // Two-way sync — the "git is NOT the source of truth" state, opposite the padlock.
  'arrow.left.arrow.right': Icons.swap_horiz,
  'arrow.uturn.backward': Icons.undo,
  'arrow.clockwise': Icons.refresh,

  // -- Actions --------------------------------------------------------------------------------
  // `plus`, `pencil` and `trash` are wired: `configurations_screen.dart` opens
  // `ConfigEditorDialog` for create and edit, and the editor's own footer carries the delete.
  'plus': Icons.add,
  'pencil': Icons.edit_outlined,
  'trash': Icons.delete_outline,
  'doc.on.doc': Icons.content_copy,
  'magnifyingglass': Icons.search,
  'line.3.horizontal.decrease.circle': Icons.filter_alt_outlined,
  // Export CSV. `ios_share` is the same up-out-of-a-box glyph SF draws; `file_upload` would
  // read as "send this to a server", which is the opposite of what the button does.
  'square.and.arrow.up': Icons.ios_share,
  'square.and.arrow.down': Icons.file_download_outlined,
  'eye': Icons.visibility_outlined,
  'eye.slash': Icons.visibility_off_outlined,
  'stop.circle': Icons.stop_circle_outlined,
  'stop.fill': Icons.stop,
  'link': Icons.link,
  'gearshape': Icons.settings_outlined,
  // SF names the same glyph both ways depending on vintage; both land here so a future view
  // cannot miss by one character and get the fallback circle.
  'gear': Icons.settings_outlined,
  'key.horizontal': Icons.key_outlined,

  // -- Appearance -----------------------------------------------------------------------------
  // The theme picker in Settings. SF's own half-filled circle is what macOS uses for "match the
  // system", and Material's `contrast` is the closest thing that reads as the same idea — a
  // gear here would collide with the settings glyph two rows up.
  'circle.lefthalf.filled': Icons.contrast,
  'sun.max': Icons.light_mode_outlined,
  'moon': Icons.dark_mode_outlined,

  // -- Files, workspace, GitOps ---------------------------------------------------------------
  'folder': Icons.folder_outlined,
  'folder.badge.plus': Icons.create_new_folder_outlined,
  // "No GitOps workspace" — a folder that is absent, not one that is broken.
  'folder.badge.questionmark': Icons.folder_off_outlined,
  'doc.text': Icons.description_outlined,
  'doc.text.magnifyingglass': Icons.find_in_page_outlined,
  'square.stack.3d.up': Icons.layers_outlined,
  // Diff / Drift. The branching glyph, because the screen is git-shaped: local tree vs tenant.
  'arrow.triangle.branch': Icons.call_split,
  'clock.arrow.circlepath': Icons.history,
  'list.bullet.rectangle': Icons.list_alt_outlined,
  'list.bullet.clipboard': Icons.assignment_outlined,

  // -- Resource kinds and sidebar sections ----------------------------------------------------
  // Every value of `ReadOnlyKind.symbol` must appear in this section; a kind added without a row
  // renders as the fallback circle in the sidebar, on its dashboard tile and in its empty state
  // at once. The icon test asserts it.
  'laptopcomputer': Icons.laptop_mac,
  'person': Icons.person_outline,
  'person.2': Icons.people_outline,
  'person.3': Icons.groups_outlined,
  'person.crop.rectangle': Icons.account_box_outlined,
  'bag': Icons.shopping_bag_outlined,
  'bag.badge.plus': Icons.add_shopping_cart,
  'cart': Icons.shopping_cart_outlined,
  'shippingbox': Icons.inventory_2_outlined,
  'server.rack': Icons.dns_outlined,
  'building.2': Icons.business_outlined,
  'apple.logo': Icons.apple,
  'square.grid.2x2': Icons.grid_view_outlined,
  'stethoscope': Icons.monitor_heart_outlined,
  'terminal': Icons.terminal,
  'chevron.left.forwardslash.chevron.right': Icons.code,
  'sparkles': Icons.auto_awesome,
};

/// What an unmapped name draws.
///
/// A neutral circle, and specifically NOT a broken-image or error glyph: the Swift app's own
/// `SidebarItem.symbol` fell through to `"circle"` for the same reason, and a screen whose icon
/// is missing is still a screen the user needs to click. It is also deliberately not
/// `questionmark.circle`'s glyph, which is a REAL mapping meaning "unknown data" — reusing it
/// would make a missing translation indistinguishable from a resource the tenant could not
/// identify.
const IconData abIconFallback = Icons.circle_outlined;

/// The icon for an SF Symbol name, always. Never throws and never returns null: this is called
/// from `build`, where a missing row must cost one bland glyph, not a red error box in the
/// sidebar. Coverage is a test's job (see `test/sf_icons_test.dart`), not a runtime assertion.
IconData abIcon(String sfSymbolName) =>
    sfSymbolIcons[sfSymbolName] ?? abIconFallback;

/// The icon for [sfSymbolName], or null if nothing is mapped. For the callers that need to tell
/// "missing" from "deliberately a circle" — chiefly the coverage test, which cannot use [abIcon]
/// to detect a gap because `circle` legitimately maps to the fallback's glyph.
IconData? abIconOrNull(String sfSymbolName) => sfSymbolIcons[sfSymbolName];
