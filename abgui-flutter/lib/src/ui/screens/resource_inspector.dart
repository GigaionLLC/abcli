// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The read-only inspector every inventory screen opens on a double-click.
///
/// **What it is not.** The Swift app opened a TYPED sheet per kind (`InspectSheets.swift`), each
/// of which spent another abctl call to fetch detail Apple does not put in the list payload — a
/// device's assigned MDM server, a blueprint's six resolved member collections. Those sheets are
/// their own screens with their own load state and belong in a dialogs layer; this is the
/// fallback underneath them, and it deliberately spends NO API call: everything it shows is
/// already in the row the table is holding.
///
/// That is worth having on its own. A table shows three or four columns of a payload that
/// routinely carries fifteen attributes, and "what else does Apple say about this device?" was
/// otherwise a question only `abctl … -o json` in a terminal could answer.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:abgui/src/models/resource.dart';
import 'package:abgui/src/platform/clipboard.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// Open the inspector for one row. [title] names the KIND ('Devices', 'Blueprints'); the row
/// names itself underneath.
Future<void> showResourceInspector(
  BuildContext context, {
  required String title,
  required String symbol,
  required Resource resource,
}) => showDialog<void>(
  context: context,
  builder: (BuildContext context) =>
      _ResourceInspector(title: title, symbol: symbol, resource: resource),
);

class _ResourceInspector extends StatelessWidget {
  const _ResourceInspector({
    required this.title,
    required this.symbol,
    required this.resource,
  });

  final String title;
  final String symbol;
  final Resource resource;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return Dialog(
      backgroundColor: ab.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: ab.line),
        borderRadius: BorderRadius.circular(AbSpace.radius),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(context, ab),
            Divider(color: ab.line, height: 1),
            Flexible(
              // Selectable as a whole: the values here are serials, ids and dates that end up
              // pasted into a ticket or another tool, and a detail view you cannot copy out of
              // is a detail view you retype by hand.
              child: SelectionArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AbSpace.lg,
                    vertical: AbSpace.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final _Field field in _fields())
                        _FieldRow(field: field),
                    ],
                  ),
                ),
              ),
            ),
            Divider(color: ab.line, height: 1),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AbColors ab) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AbSpace.lg,
      AbSpace.md,
      AbSpace.sm,
      AbSpace.md,
    ),
    child: Row(
      children: <Widget>[
        Icon(abIcon(symbol), size: 16, color: ab.dim),
        const SizedBox(width: AbSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(title.toUpperCase(), style: AbType.label(context)),
              const SizedBox(height: 2),
              Text(
                resource.displayName(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: ab.text,
                ),
              ),
            ],
          ),
        ),
        ToolbarButton(
          icon: abIcon('xmark'),
          label: 'Close',
          tooltip: 'Close this inspector.',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );

  Widget _footer(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AbSpace.md,
      vertical: AbSpace.sm,
    ),
    child: Row(
      children: <Widget>[
        // No Edit, no Delete, no Assign, and that stays true now that the app HAS those verbs.
        // An inspector is where such a control looks most reasonable and is least safe: this
        // sheet is opened by a single click on a row, from six different tables, and it renders
        // an attribute bag rather than the thing being changed. Every write in abgui is reached
        // from the table that owns the object — Configurations opens `ConfigEditorDialog`,
        // Blueprints opens `MembershipDialog`, Devices opens `AssignDialog` — because those are
        // the screens that can show a plan, a pre-flight and a receipt around it.
        _CopyJsonButton(resource: resource),
        const Spacer(),
        ToolbarButton(
          icon: abIcon('checkmark'),
          label: 'Done',
          tooltip: 'Close this inspector.',
          weight: AbToolbarWeight.titled,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );

  /// Every field, in reading order: the JSON:API identity first, then the attribute bag by key.
  ///
  /// Sorted alphabetically rather than left in Apple's order, which is neither stable across
  /// endpoints nor meaningful: a reader looking for `serialNumber` in a fifteen-key bag can find
  /// it by name, and cannot find it by remembering where it was last time.
  List<_Field> _fields() {
    final fields = <_Field>[
      _Field('type', resource.type.isEmpty ? '—' : resource.type),
      _Field('id', resource.id.isEmpty ? '—' : resource.id),
    ];
    final Object? raw = resource.attributes?.raw;
    if (raw is Map) {
      final keys = raw.keys.map((Object? key) => '$key').toList()..sort();
      for (final String key in keys) {
        fields.add(_Field(key, _render(raw[key])));
      }
    } else if (raw != null) {
      // An attributes bag that is not an object at all. Rare, and worth showing verbatim rather
      // than swallowing: it means abctl (or Apple) changed the payload shape, which is the whole
      // diagnosis for a table that has gone blank.
      fields.add(_Field('attributes', _render(raw)));
    }
    return fields;
  }

  /// One value as text. Nested objects and arrays are pretty-printed rather than flattened —
  /// `mdmDetails` and `roles` are where the interesting detail lives, and `{…}` would hide it.
  static String _render(Object? value) {
    if (value == null) return '—';
    if (value is String) return value.isEmpty ? '—' : value;
    if (value is num || value is bool) return '$value';
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      // Non-encodable content cannot happen from `jsonDecode` output, but this runs over data a
      // tenant controls and a throw here would take down the whole inspector for one odd key.
      return '$value';
    }
  }
}

@immutable
class _Field {
  const _Field(this.label, this.value);

  final String label;
  final String value;
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field});

  final _Field field;

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AbSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 170,
            child: Text(
              field.label,
              style: AbType.mono(context, size: 11.5, color: ab.faint),
            ),
          ),
          const SizedBox(width: AbSpace.sm),
          Expanded(
            child: Text(
              field.value,
              // Wraps, unlike a table cell: a pretty-printed `mdmDetails` is the reason someone
              // opened this, and ellipsising it would leave them exactly where they started.
              style: AbType.mono(context, size: 11.5, color: ab.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Copies the row as the JSON abctl printed. Confirms for [AbClipboard.confirmationDuration], and
/// says so when the platform refused — a copy button that lies is worse than one that is missing,
/// because the user walks away believing they have the payload.
class _CopyJsonButton extends StatefulWidget {
  const _CopyJsonButton({required this.resource});

  final Resource resource;

  @override
  State<_CopyJsonButton> createState() => _CopyJsonButtonState();
}

class _CopyJsonButtonState extends State<_CopyJsonButton> {
  Timer? _reset;
  bool _copied = false;
  bool _failed = false;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final String text = const JsonEncoder.withIndent(
      '  ',
    ).convert(widget.resource.toJson());
    final bool ok = await AbClipboard.copy(text);
    if (!mounted) return;
    setState(() {
      _copied = ok;
      _failed = !ok;
    });
    _reset?.cancel();
    _reset = Timer(AbClipboard.confirmationDuration, () {
      if (!mounted) return;
      setState(() {
        _copied = false;
        _failed = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final String label = _copied
        ? 'Copied'
        : (_failed ? 'Couldn\'t copy' : 'Copy JSON');
    return ToolbarButton(
      icon: abIcon(_copied ? 'checkmark' : 'doc.on.doc'),
      label: label,
      tooltip: 'Copy this row exactly as abctl printed it, as JSON.',
      weight: AbToolbarWeight.titled,
      onPressed: () => unawaited(_copy()),
    );
  }
}
