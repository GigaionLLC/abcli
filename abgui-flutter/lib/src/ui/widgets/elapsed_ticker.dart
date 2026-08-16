// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:abgui/src/models/command_record.dart' show DurationText;
import 'package:abgui/src/ui/theme.dart';

/// A live "…and counting" duration for a command that is still running.
///
/// **This widget exists to contain a rebuild.** The Swift app drove its ticking elapsed times
/// from a `TimelineView` high in the view tree, and the console/footer re-rendered on every
/// tick — with a long plan on screen that meant re-laying out thousands of rows twice a second
/// to move one digit. The rule here is that the timer lives at the LEAF: `setState` on this
/// State object marks exactly this widget dirty and nothing above it. Never lift the timer into
/// a parent, and never pass a `DateTime.now()` down from one — that reintroduces the same bug
/// with different spelling.
///
/// **It stops when idle.** A finished command has a fixed duration, so the timer is cancelled
/// the moment [finishedAt] arrives (and never started if the widget is built with one). A
/// command log with 200 completed rows therefore holds zero timers.
class ElapsedTicker extends StatefulWidget {
  const ElapsedTicker({
    super.key,
    required this.startedAt,
    this.finishedAt,
    this.style,
    this.clock = DateTime.now,
    this.interval = const Duration(milliseconds: 500),
  });

  final DateTime startedAt;

  /// Non-null once the command has ended: the reading freezes and the timer is retired.
  final DateTime? finishedAt;

  final TextStyle? style;

  /// The clock, injected so a test can advance time without sleeping. Production always uses
  /// the default; nothing else should pass this.
  final DateTime Function() clock;

  /// 500ms, not 1s: at one second the tenths digit visibly stutters (it skips values), which
  /// reads as a hung UI — the exact impression this widget exists to prevent.
  final Duration interval;

  @override
  State<ElapsedTicker> createState() => _ElapsedTickerState();
}

class _ElapsedTickerState extends State<ElapsedTicker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(ElapsedTicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A record is replaced (not mutated) when it finishes, so the finish arrives as a new
    // widget configuration rather than as a callback. Re-deciding here is what actually stops
    // the timer in production.
    if (oldWidget.finishedAt != widget.finishedAt ||
        oldWidget.interval != widget.interval) {
      _syncTimer();
    }
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (widget.finishedAt != null) return;
    _timer = Timer.periodic(widget.interval, (_) {
      // Guarded because a periodic timer can outlive the element by one tick if disposal and
      // the tick land in the same frame.
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// How long the command has taken: its final duration once finished, else the running total.
  /// Clamped at zero — a machine whose clock steps backwards mid-run must not print "-3.0s".
  Duration get _elapsed {
    final end = widget.finishedAt ?? widget.clock();
    final span = end.difference(widget.startedAt);
    return span.isNegative ? Duration.zero : span;
  }

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final running = widget.finishedAt == null;
    return Text(
      // One formatter for every duration in the app (models/command_record.dart), so the log,
      // the timing panel and this ticker can never disagree about what "1m 4s" looks like.
      DurationText.short(_elapsed),
      style:
          widget.style ??
          AbType.mono(context, size: 11, color: running ? ab.drift : ab.faint),
    );
  }
}
