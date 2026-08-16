// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/models/contract.dart';
import 'package:abgui/src/state/command_log_store.dart';
import 'package:abgui/src/state/connection_store.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';

/// What one screen wants said about itself in the status bar.
///
/// Counts live HERE rather than in the screen's own chrome because they are the same three
/// numbers on every screen, and because a table that reports "1,204 rows · 3 selected" in its own
/// header spends header width on it nineteen times over.
@immutable
class ShellStatus {
  const ShellStatus({this.rowCount, this.selectedCount, this.detail});

  static const ShellStatus empty = ShellStatus();

  /// Rows currently listed — AFTER filtering, because that is the number on screen. A screen that
  /// wants to say "5,000 devices, 120 shown" puts the total in [detail]; the bar will not invent
  /// the distinction for it.
  final int? rowCount;

  /// Rows the user has picked. Null (not zero) when the screen has no selection model at all —
  /// "0 selected" on a display-only table is noise that never changes.
  final int? selectedCount;

  /// Right-aligned secondary info, in the screen's own words: when the pane last read cleanly,
  /// which window an audit query covers, how many rows a filter is hiding.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is ShellStatus &&
      other.rowCount == rowCount &&
      other.selectedCount == selectedCount &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(rowCount, selectedCount, detail);
}

/// The channel a screen uses to fill the status bar, and the reason the status bar is not a
/// provider.
///
/// **Why a `ChangeNotifier` and not Riverpod.** These numbers change on every keystroke in a
/// search box and on every click in a table. Routing that through a provider would invalidate a
/// provider — and therefore rebuild whatever watches it — once per keystroke, which is the same
/// per-event invalidation the progress transcript was pulled out of Riverpod to avoid (see
/// `progress_sink.dart`). Here the notifier is listened to by exactly one widget, [StatusBar], so
/// a burst of typing repaints a 22px strip and nothing else.
///
/// **Why the reports are keyed by destination.** The detail column is an `IndexedStack`: the
/// screens the user has visited stay alive and do NOT rebuild when they are hidden. A single
/// current-status slot would therefore keep showing the Devices row count while the user reads
/// the Diff screen, because Devices has no reason to rebuild and correct it. Keying the reports
/// means switching screens just changes which slot is on display, and every screen's numbers stay
/// true whether or not it is the one being drawn.
class ShellStatusController extends ChangeNotifier {
  final Map<String, ShellStatus> _byDestination = <String, ShellStatus>{};
  String _visible = '';
  bool _disposed = false;

  /// What the bar should draw right now.
  ShellStatus get visible => _byDestination[_visible] ?? ShellStatus.empty;

  /// Which destination is on screen. Called by the shell when the selection changes.
  void show(String destinationId) {
    if (destinationId == _visible) return;
    _visible = destinationId;
    _notify();
  }

  /// A screen states its own numbers. Safe to call from `build`: see [_notify].
  void report(String destinationId, ShellStatus status) {
    if (_byDestination[destinationId] == status) return;
    _byDestination[destinationId] = status;
    // A hidden screen's numbers are recorded but change nothing on screen, so they must not cost
    // a notification — a background refresh landing on an unseen pane would otherwise repaint the
    // bar for no visible reason.
    if (destinationId != _visible) return;
    _notify();
  }

  /// Forget a screen's numbers (a pane that has been torn down, or a test cleaning up).
  void clear(String destinationId) {
    if (_byDestination.remove(destinationId) == null) return;
    if (destinationId != _visible) return;
    _notify();
  }

  /// Notify, but never DURING a build.
  ///
  /// Screens report their counts from where the counts are computed, which is usually inside
  /// `build`. Notifying there marks [StatusBar] dirty while the frame is already building, and
  /// Flutter asserts on exactly that. Deferring to the end of the frame keeps the reporting call
  /// site simple — the alternative is every screen remembering to wrap its report in a
  /// post-frame callback, which is the kind of rule that holds for four screens and fails on the
  /// fifth.
  void _notify() {
    final SchedulerPhase phase = SchedulerBinding.instance.schedulerPhase;
    final bool midFrame =
        phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;
    if (!midFrame) {
      notifyListeners();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      if (_disposed) return;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    // The flag exists for the deferred notification above: a controller disposed between the
    // report and the end of the frame would otherwise throw from the post-frame callback.
    _disposed = true;
    super.dispose();
  }
}

/// Hands the [ShellStatusController] down to the screens.
///
/// `maybeOf`, never a non-null `of`: a screen must be usable outside the shell (in a widget test,
/// in a preview harness) and a table that crashed because there was no status bar to talk to
/// would be a screen the shell had captured.
class ShellStatusScope extends InheritedWidget {
  const ShellStatusScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final ShellStatusController controller;

  static ShellStatusController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ShellStatusScope>()
      ?.controller;

  @override
  bool updateShouldNotify(ShellStatusScope oldWidget) =>
      oldWidget.controller != controller;
}

/// Tells everything under one screen WHICH screen it is in.
///
/// The shell wraps each `IndexedStack` slot in one of these, and it exists for a single reason:
/// [ShellStatusController] keys its reports by destination, and the thing that actually knows the
/// numbers — the table — is several widgets below the screen and has no idea which pane it is
/// drawing. Passing the id down the tree instead of through nineteen constructors means a screen
/// gets a working status bar by using the app's table, and cannot get it wrong.
///
/// The id never changes for a given slot, so `updateShouldNotify` is effectively always false and
/// depending on this costs a dependency registration and nothing else.
class ShellSlot extends InheritedWidget {
  const ShellSlot({
    super.key,
    required this.destinationId,
    required super.child,
  });

  /// [ShellDestination.id] — the enum NAME, for the reason that type gives: an index changes the
  /// moment a screen is inserted.
  final String destinationId;

  /// Null outside the shell (a screen pumped alone in a test, a dialog). Callers must treat that
  /// as "nowhere to report", never as an error: a screen has to be usable on its own.
  static String? idOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellSlot>()?.destinationId;

  @override
  bool updateShouldNotify(ShellSlot oldWidget) =>
      oldWidget.destinationId != destinationId;
}

/// The bottom strip: how much is on screen, how much of it is picked, and what abgui is doing.
///
/// Left is about the DATA the user is looking at; right is about the TOOL. Keeping those apart is
/// what lets someone find "how many did I select?" without reading the whole bar.
class StatusBar extends ConsumerWidget {
  const StatusBar({super.key, this.controller});

  /// Normally read from [ShellStatusScope]. The parameter exists so the bar can be built
  /// standalone in a test without a shell around it.
  final ShellStatusController? controller;

  static const double height = 22;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final ShellStatusController? status =
        controller ?? ShellStatusScope.maybeOf(context);
    // Two notifications per command — a start and a finish — never one per line of output.
    final int running = ref.watch(
      commandLogProvider.select((CommandLog log) => log.runningCount),
    );
    final Connection connection = ref.watch(connectionProvider);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border(top: BorderSide(color: ab.line)),
      ),
      child: SizedBox(
        height: height,
        child: Row(
          children: <Widget>[
            const SizedBox(width: AbSpace.md),
            Expanded(
              child: status == null
                  ? const SizedBox.shrink()
                  : ListenableBuilder(
                      listenable: status,
                      builder: (BuildContext context, Widget? _) =>
                          _Counts(status: status.visible),
                    ),
            ),
            if (status != null)
              ListenableBuilder(
                listenable: status,
                builder: (BuildContext context, Widget? _) {
                  final String? detail = status.visible.detail;
                  if (detail == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(right: AbSpace.md),
                    child: MonoText(detail, size: 10.5, color: ab.faint),
                  );
                },
              ),
            if (running > 0) ...<Widget>[
              MonoText(
                running == 1 ? '1 running' : '$running running',
                size: 10.5,
                color: ab.drift,
              ),
              const SizedBox(width: AbSpace.md),
            ],
            MonoText(
              switch (connection) {
                ConnectionConnected(:final VersionInfo version) =>
                  'abctl ${version.version}',
                ConnectionChecking() => 'checking abctl…',
                ConnectionFailed() => 'abctl unavailable',
                ConnectionUnknown() => 'abctl not checked',
              },
              size: 10.5,
              color: connection is ConnectionFailed ? ab.danger : ab.faint,
            ),
            const SizedBox(width: AbSpace.md),
          ],
        ),
      ),
    );
  }
}

/// The left half: rows, and how many of them are picked.
class _Counts extends StatelessWidget {
  const _Counts({required this.status});

  final ShellStatus status;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    final int? rows = status.rowCount;
    final int? selected = status.selectedCount;
    if (rows == null && selected == null) return const SizedBox.shrink();
    final StringBuffer text = StringBuffer();
    if (rows != null) {
      text.write('${_grouped(rows)} ${rows == 1 ? 'row' : 'rows'}');
    }
    if (selected != null && selected > 0) {
      if (text.isNotEmpty) text.write('  ·  ');
      text.write('${_grouped(selected)} selected');
    }
    return MonoText(
      text.toString(),
      size: 10.5,
      // Selection is a state the user put the app INTO, and it changes what the toolbar's
      // controls will act on, so it is the one thing down here that gets the accent.
      color: (selected ?? 0) > 0 ? ab.accent : ab.dim,
    );
  }

  /// Thousands separators, by hand. There is no `intl` in this app and adding one for a status
  /// bar would be a dependency for a comma — but the comma earns itself: a raw `5000` next to
  /// `50000` in a 10px face is genuinely hard to tell apart, and misreading how many devices you
  /// are looking at is the specific mistake this app exists to prevent.
  static String _grouped(int value) {
    final String digits = value.abs().toString();
    final StringBuffer out = StringBuffer(value < 0 ? '-' : '');
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}
