// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

/// The design system. One place that decides colour, type and density, so no widget invents
/// its own — the Swift app leaked hard-coded `.red` and `.secondary` into a dozen views and
/// there was no way to answer "what does 'drift' look like" without reading all of them.
///
/// The identity is cyanotype: the product's core noun is Blueprint, so the palette is drafting
/// ink. Dark is the cyanotype (deep blue ground, pale rules); light is the print (cool paper,
/// blue ink). Both are designed, not inverted — the accent has to stay legible on either
/// ground, and the semantic colours have to keep their distance from each other on both.

/// Semantic colours and surfaces that Material's `ColorScheme` has no slot for.
///
/// These are SEPARATE from the accent on purpose. `primary` says "this control is actionable";
/// [drift], [ok] and [danger] say what the DATA is doing. Wiring drift to the accent would mean
/// a screen full of pending changes reads as a screen full of buttons.
@immutable
class AbColors extends ThemeExtension<AbColors> {
  const AbColors({
    required this.canvas,
    required this.surface,
    required this.raised,
    required this.sunken,
    required this.line,
    required this.lineSoft,
    required this.text,
    required this.dim,
    required this.faint,
    required this.accent,
    required this.accentSoft,
    required this.drift,
    required this.driftBg,
    required this.ok,
    required this.okBg,
    required this.danger,
    required this.dangerBg,
  });

  /// The window ground, behind every pane.
  final Color canvas;

  /// A pane sitting on the canvas.
  final Color surface;

  /// Chrome that must read as ABOVE the surface: table headers, the sidebar, status bars.
  final Color raised;

  /// Selection and pressed states — reads as pushed INTO the surface.
  final Color sunken;

  /// Structural hairlines: pane borders, table header rules.
  final Color line;

  /// Row separators. Deliberately fainter than [line]: at the density this app runs, a full
  /// strength rule between every row turns a table into a grid of boxes.
  final Color lineSoft;

  /// Primary reading colour.
  final Color text;

  /// Secondary text: values in a table, supporting copy.
  final Color dim;

  /// Tertiary: column headers, eyebrow labels, timestamps.
  final Color faint;

  /// The interactive accent.
  final Color accent;

  /// The accent at rest — borders and rails where full strength would shout.
  final Color accentSoft;

  /// Pending / changed / needs-attention. Amber, because it must not be mistaken for either
  /// "fine" or "destructive" at a glance in a plan row.
  final Color drift;
  final Color driftBg;

  /// In sync, enrolled, succeeded.
  final Color ok;
  final Color okBg;

  /// Destructive: a delete in a plan, a failed write, a prune warning.
  final Color danger;
  final Color dangerBg;

  static const AbColors light = AbColors(
    canvas: Color(0xFFEDF1F6),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFE3EAF2),
    sunken: Color(0xFFD6E0EA),
    line: Color(0xFFBFD0E0),
    lineSoft: Color(0xFFD8E2EC),
    text: Color(0xFF0C1F33),
    dim: Color(0xFF4C6379),
    faint: Color(0xFF7B90A4),
    accent: Color(0xFF1B6EA8),
    accentSoft: Color(0xFF8FBBD9),
    drift: Color(0xFFA65C11),
    driftBg: Color(0xFFFBEEDC),
    ok: Color(0xFF17724F),
    okBg: Color(0xFFDCEFE6),
    danger: Color(0xFFA93430),
    dangerBg: Color(0xFFFAE3E2),
  );

  static const AbColors dark = AbColors(
    canvas: Color(0xFF061524),
    surface: Color(0xFF0B2036),
    raised: Color(0xFF102C46),
    sunken: Color(0xFF163A59),
    line: Color(0xFF234A6C),
    lineSoft: Color(0xFF17334E),
    text: Color(0xFFDBE8F4),
    dim: Color(0xFF91ACC6),
    faint: Color(0xFF63819D),
    accent: Color(0xFF5FB3E5),
    accentSoft: Color(0xFF2C5F84),
    drift: Color(0xFFE8A24A),
    driftBg: Color(0xFF3A2A12),
    ok: Color(0xFF56C39A),
    okBg: Color(0xFF103328),
    danger: Color(0xFFF0716B),
    dangerBg: Color(0xFF3B1A19),
  );

  @override
  AbColors copyWith({
    Color? canvas,
    Color? surface,
    Color? raised,
    Color? sunken,
    Color? line,
    Color? lineSoft,
    Color? text,
    Color? dim,
    Color? faint,
    Color? accent,
    Color? accentSoft,
    Color? drift,
    Color? driftBg,
    Color? ok,
    Color? okBg,
    Color? danger,
    Color? dangerBg,
  }) {
    return AbColors(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      raised: raised ?? this.raised,
      sunken: sunken ?? this.sunken,
      line: line ?? this.line,
      lineSoft: lineSoft ?? this.lineSoft,
      text: text ?? this.text,
      dim: dim ?? this.dim,
      faint: faint ?? this.faint,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      drift: drift ?? this.drift,
      driftBg: driftBg ?? this.driftBg,
      ok: ok ?? this.ok,
      okBg: okBg ?? this.okBg,
      danger: danger ?? this.danger,
      dangerBg: dangerBg ?? this.dangerBg,
    );
  }

  @override
  AbColors lerp(ThemeExtension<AbColors>? other, double t) {
    if (other is! AbColors) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AbColors(
      canvas: c(canvas, other.canvas),
      surface: c(surface, other.surface),
      raised: c(raised, other.raised),
      sunken: c(sunken, other.sunken),
      line: c(line, other.line),
      lineSoft: c(lineSoft, other.lineSoft),
      text: c(text, other.text),
      dim: c(dim, other.dim),
      faint: c(faint, other.faint),
      accent: c(accent, other.accent),
      accentSoft: c(accentSoft, other.accentSoft),
      drift: c(drift, other.drift),
      driftBg: c(driftBg, other.driftBg),
      ok: c(ok, other.ok),
      okBg: c(okBg, other.okBg),
      danger: c(danger, other.danger),
      dangerBg: c(dangerBg, other.dangerBg),
    );
  }
}

/// How much vertical room a table row gets. An admin auditing five thousand devices and one
/// reading a single blueprint want different answers; macOS gave one. Persisted per screen.
enum AbDensity {
  comfortable(rowHeight: 30, fontSize: 13),
  compact(rowHeight: 23, fontSize: 12);

  const AbDensity({required this.rowHeight, required this.fontSize});

  final double rowHeight;
  final double fontSize;
}

/// Type. Two families, chosen for what they encode rather than for looks:
///
/// * The SANS is the platform's own UI face, so prose and controls sit correctly on each OS
///   without shipping a font.
/// * The MONO carries every piece of machine data — serials, versions, hashes, argv, paths,
///   timestamps — and is always paired with tabular figures. Proportional digits let a
///   mis-sorted version column look sorted, which is the exact failure this app must not have.
abstract final class AbType {
  /// Resolved by the platform; naming a family that does not exist silently falls back.
  static const List<String> monoFallback = <String>[
    'SF Mono',
    'Cascadia Mono',
    'Consolas',
    'DejaVu Sans Mono',
    'Menlo',
    'monospace',
  ];

  /// Machine data. ALWAYS tabular so columns of digits align.
  static TextStyle mono(
    BuildContext context, {
    double? size,
    Color? color,
    FontWeight? weight,
  }) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return TextStyle(
      fontFamily: monoFallback.first,
      fontFamilyFallback: monoFallback.sublist(1),
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      fontSize: size ?? 12.5,
      color: color ?? ab.text,
      fontWeight: weight,
      height: 1.35,
    );
  }

  /// Column headers and eyebrow labels: small, wide-tracked, quiet.
  static TextStyle label(BuildContext context, {Color? color}) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return TextStyle(
      fontFamily: monoFallback.first,
      fontFamilyFallback: monoFallback.sublist(1),
      fontSize: 10,
      letterSpacing: 1.2,
      fontWeight: FontWeight.w500,
      color: color ?? ab.faint,
    );
  }
}

/// Spacing scale. Named so a review can ask "why 14?" and get an answer.
abstract final class AbSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;

  /// Corner radius. Small on purpose: this is a dense technical tool, and generous rounding
  /// on a 23px table row reads as a toy.
  static const double radius = 3;
}

ThemeData abTheme(Brightness brightness) {
  final ab = brightness == Brightness.dark ? AbColors.dark : AbColors.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: ab.accent,
        brightness: brightness,
      ).copyWith(
        primary: ab.accent,
        surface: ab.surface,
        error: ab.danger,
        // Flutter's generated onPrimary can land at a contrast that fails on our accent, because
        // the seed algorithm knows nothing about the exact accent we pinned above.
        onPrimary: brightness == Brightness.dark
            ? AbColors.dark.canvas
            : Colors.white,
        onSurface: ab.text,
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: ab.canvas,
    canvasColor: ab.canvas,
    dividerColor: ab.line,
    extensions: <ThemeExtension<dynamic>>[ab],
    dividerTheme: DividerThemeData(color: ab.line, thickness: 1, space: 1),
    // Desktop density. Material's default targets a fingertip; every one of these controls is
    // driven by a mouse on a screen showing thousands of rows.
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textTheme: Typography.material2021(
      platform: TargetPlatform.linux,
    ).black.apply(bodyColor: ab.text, displayColor: ab.text),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border.all(color: ab.line),
        borderRadius: BorderRadius.circular(AbSpace.radius),
      ),
      textStyle: TextStyle(fontSize: 12, color: ab.text),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(9),
      thumbVisibility: WidgetStateProperty.all(true),
      radius: const Radius.circular(5),
    ),
  );
}
