// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/shell/sidebar_item.dart';
import 'package:abgui/src/ui/theme.dart';

/// The navigation column: three labelled sections of [SidebarItemView]s.
///
/// **This widget is never replaced by a spinner, and it never blanks.** That is the whole reason
/// the shell is laid out the way it is. The Swift sidebar sat above a `.safeAreaInset` footer
/// whose height was data-driven — it grew and shrank with the last abctl command line — so the
/// inset re-measured exactly when a run started, and the entire sidebar went blank for as long as
/// the plan took. Here the sidebar is a sibling of the run strip in a plain `Column`: nothing
/// about a running command can reach into this subtree, and the only thing that rebuilds while a
/// command runs is the one row whose pane is loading (see [sidebarPipOf]).
///
/// It is a `StatelessWidget` deliberately. Selection is owned by `RootShell` (which has to hold it
/// anyway, for the `IndexedStack` index), and a sidebar that also remembered a selection would be
/// a second copy of that fact — the version of it that goes out of step.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.selected,
    required this.onSelect,
    this.collapsed = false,
  });

  final ShellDestination selected;
  final ValueChanged<ShellDestination> onSelect;

  /// Icon-rail mode: same rows, same order, same pips — titles and section headers drop out.
  /// The rows do NOT change identity between modes, so collapsing keeps every row's element (and
  /// its provider subscription) alive instead of tearing down nineteen subscriptions and building
  /// nineteen more.
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;

    final List<Widget> children = <Widget>[];
    for (final ShellSection section in ShellSection.values) {
      children.add(
        collapsed
            // A rule instead of a word. The grouping is real information — GitOps screens read a
            // folder, Inventory screens read the tenant — and losing it in the rail would make the
            // collapsed sidebar an undifferentiated column of nineteen glyphs.
            ? Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AbSpace.sm,
                  vertical: AbSpace.sm,
                ),
                child: Divider(height: 1, color: ab.line),
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(
                  AbSpace.md,
                  AbSpace.md,
                  AbSpace.sm,
                  AbSpace.xs,
                ),
                child: Text(
                  section.title.toUpperCase(),
                  style: AbType.label(context),
                ),
              ),
      );
      for (final ShellDestination destination in section.destinations) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AbSpace.xs),
            child: SidebarItemView(
              // Keyed by destination so a rebuild in either mode matches rows up by WHAT they
              // are, never by position — the pip's subscription belongs to the pane, and a row
              // that got re-matched to a neighbour would show that neighbour's failure.
              key: ValueKey<String>(destination.id),
              destination: destination,
              selected: destination == selected,
              onSelect: onSelect,
              collapsed: collapsed,
            ),
          ),
        );
      }
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border(right: BorderSide(color: ab.line)),
      ),
      child: Semantics(
        container: true,
        label: 'Sections',
        child: ListView(
          padding: const EdgeInsets.only(bottom: AbSpace.md),
          // The window's own scroll gestures belong to the content pane; a sidebar that claimed
          // `primary` would swallow a trackpad flick aimed at a five-thousand-row table.
          primary: false,
          children: children,
        ),
      ),
    );
  }
}
