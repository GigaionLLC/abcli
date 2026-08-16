// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'package:abgui/src/ui/theme.dart';

/// Filter-match highlighting, in one place.
///
/// Every cell in every table renders through this, because "why is this row on screen?" is a
/// question a filtered table must answer in the row itself — a list that silently drops 4,900
/// of 5,000 rows and highlights nothing is asking the user to trust it.
abstract final class AbHighlight {
  /// The highlight treatment: a wash of the soft accent plus weight. Weight matters — it is the
  /// half of the signal that survives on a monochrome display or with no colour vision.
  static TextStyle style(BuildContext context, TextStyle base) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return base.copyWith(
      backgroundColor: ab.accentSoft,
      color: ab.text,
      fontWeight: FontWeight.w700,
    );
  }

  /// [text] split into spans, with every case-insensitive occurrence of [needle] wearing
  /// [highlighted].
  ///
  /// Deliberately a manual scan and NOT a `RegExp`: the needle is whatever the user typed into
  /// the search box, so `serial (old)` or `10.2+` would throw on pattern compilation and take
  /// out the whole pane. Any escaping helper we wrote instead would be one more thing to get
  /// wrong for a job `indexOf` already does.
  static List<InlineSpan> spans(
    String text,
    String needle, {
    required TextStyle base,
    required TextStyle highlighted,
  }) {
    final trimmed = needle.trim();
    if (trimmed.isEmpty || text.isEmpty) {
      return <InlineSpan>[TextSpan(text: text, style: base)];
    }
    final haystack = text.toLowerCase();
    final target = trimmed.toLowerCase();
    final out = <InlineSpan>[];
    var cursor = 0;
    while (cursor < text.length) {
      final hit = haystack.indexOf(target, cursor);
      if (hit < 0) {
        out.add(TextSpan(text: text.substring(cursor), style: base));
        break;
      }
      if (hit > cursor) {
        out.add(TextSpan(text: text.substring(cursor, hit), style: base));
      }
      out.add(
        TextSpan(
          text: text.substring(hit, hit + target.length),
          style: highlighted,
        ),
      );
      cursor = hit + target.length;
    }
    return out;
  }
}

/// Machine data: serials, versions, ids, paths, counts, timestamps.
///
/// Always monospaced and always tabular (via [AbType.mono]) so a column of digits lines up.
/// The reason is in the theme's own comment and it is not cosmetic: with proportional figures a
/// mis-sorted version column can LOOK sorted, and this app's whole job is telling a person what
/// their tenant actually contains.
class MonoText extends StatelessWidget {
  const MonoText(
    this.text, {
    super.key,
    this.highlight = '',
    this.size,
    this.color,
    this.weight,
    this.align,
    this.maxLines = 1,
  });

  final String text;

  /// Active filter; matching runs are highlighted. Empty means no highlighting at all.
  final String highlight;

  final double? size;
  final Color? color;
  final FontWeight? weight;
  final TextAlign? align;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final base = AbType.mono(context, size: size, color: color, weight: weight);
    return Text.rich(
      TextSpan(
        children: AbHighlight.spans(
          text,
          highlight,
          base: base,
          highlighted: AbHighlight.style(context, base),
        ),
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      textAlign: align,
    );
  }
}

/// Prose inside a data surface — a name, a model, a note. Same highlighting contract as
/// [MonoText]; the difference is only the face, because a device name is language and a serial
/// number is not.
class AbCellText extends StatelessWidget {
  const AbCellText(
    this.text, {
    super.key,
    this.highlight = '',
    this.size,
    this.color,
    this.weight,
    this.align,
    this.maxLines = 1,
  });

  final String text;
  final String highlight;
  final double? size;
  final Color? color;
  final FontWeight? weight;
  final TextAlign? align;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final base = TextStyle(
      fontSize: size ?? 13,
      color: color ?? ab.text,
      fontWeight: weight,
      height: 1.2,
    );
    return Text.rich(
      TextSpan(
        children: AbHighlight.spans(
          text,
          highlight,
          base: base,
          highlighted: AbHighlight.style(context, base),
        ),
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      textAlign: align,
    );
  }
}
