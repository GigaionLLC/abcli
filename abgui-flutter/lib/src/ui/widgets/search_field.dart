// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';

/// The search box every list screen carries.
///
/// It owns nothing: the text lives in the screen's state, because the screen is what hands it to
/// [AbTable] as a filter and what has to clear it when the user switches resources. What this
/// widget adds is the one behaviour a raw `TextField` does not have — a clear button that appears
/// only when there is something to clear, driven by the controller itself rather than by whether
/// the parent happened to rebuild.
///
/// **Why it moved here from `screens/inventory_chrome.dart`.** It was inventory furniture until
/// the membership dialog needed to search a tenant's configurations to pick one; a dialog reaching
/// into a screen file is the arrangement that file's own doc comment warns about ("that is how a
/// 'shared' widget ends up owned by whichever screen was written first"). It is re-exported from
/// `inventory_chrome.dart`, so the five screens that already used it are unchanged — the same
/// promotion `CopyButton` made out of `diagnostics_chrome.dart`, for the same reason. The name
/// keeps its `Inventory` prefix on purpose: renaming a widget four screens import buys nothing
/// and makes every future `git log -S` on it start with a rename.
class InventorySearchField extends StatelessWidget {
  const InventorySearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = 'Search',
    this.width = 210,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// Names the FIELDS that are searched, not the act of searching: on OS Releases the search
  /// reaches data the table has no column for, and this label is the only place that is said.
  final String hint;

  final double width;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AbSpace.radius),
      borderSide: BorderSide(color: ab.line),
    );
    return SizedBox(
      width: width,
      height: 26,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (BuildContext context, TextEditingValue value, Widget? _) {
          return TextField(
            controller: controller,
            onChanged: onChanged,
            style: TextStyle(fontSize: 12, color: ab.text),
            cursorColor: ab.accent,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: ab.surface,
              hintText: hint,
              hintStyle: TextStyle(fontSize: 12, color: ab.faint),
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
              prefixIcon: Icon(
                abIcon('magnifyingglass'),
                size: 14,
                color: ab.faint,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 26),
              suffixIcon: value.text.isEmpty
                  ? null
                  : Semantics(
                      button: true,
                      label: 'Clear the search',
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: () {
                          controller.clear();
                          onChanged('');
                        },
                        child: Icon(
                          abIcon('xmark.circle'),
                          size: 14,
                          color: ab.faint,
                        ),
                      ),
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 26),
              border: border,
              enabledBorder: border,
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AbSpace.radius),
                borderSide: BorderSide(color: ab.accent),
              ),
            ),
          );
        },
      ),
    );
  }
}
