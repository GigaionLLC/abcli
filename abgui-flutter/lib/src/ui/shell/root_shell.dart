// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/ui/shell/abctl_missing_banner.dart';
import 'package:abgui/src/ui/shell/context_bar.dart';
import 'package:abgui/src/ui/shell/run_strip.dart';
import 'package:abgui/src/ui/shell/sidebar.dart';
import 'package:abgui/src/ui/shell/sidebar_item.dart';
import 'package:abgui/src/ui/shell/status_bar.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// Builds the screen behind one destination. Called ONCE per destination, the first time the user
/// opens it — see [_RootShellState._children] — so the widget it returns must read its data from
/// providers rather than from arguments captured here.
typedef ShellScreenBuilder =
    Widget Function(BuildContext context, ShellDestination destination);

/// The window: context strip on top, sidebar and detail in the middle, run strip and status bar
/// pinned at the bottom.
///
/// **The layout is the fix for a bug, not a style.** The Swift app blanked its sidebar AND its
/// content for the whole duration of a command. Two separate faults produced one symptom: the
/// sidebar's footer was a `.safeAreaInset` whose height was data-driven (it grew with the last
/// abctl command line, i.e. exactly when a run started), and the detail pane had the same fault
/// from its own inset — so both columns went blank together and it read as the window dying while
/// "Computing plan…" ran. The rule that came out of it, and that this file exists to enforce:
///
/// > **Nothing is ever REPLACED by a spinner.** Progress is additive — a strip that appears
/// > beside the content, never an overlay on top of it and never a state the content becomes.
///
/// Everything follows from that:
///
///  * The five regions are siblings in a `Column`/`Row`. A running command can reach the run
///    strip and nothing else; it has no path into the sidebar's or the content pane's subtree.
///  * The detail column is an [IndexedStack], so a screen the user has already opened keeps its
///    element, its scroll offset, its selection and its in-flight load when they navigate away
///    and back. Switching screens does not re-run a load, which is what makes the sidebar cheap
///    enough to use as a status display.
///  * The sidebar's width is dragged through a [ValueNotifier] rather than `setState`, and the
///    screens are cached widget instances. Between them, a drag rebuilds a `SizedBox` and nothing
///    else — no screen re-runs `build` because someone grabbed the divider.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({
    super.key,
    required this.screenBuilder,
    this.initialDestination = ShellDestination.dashboard,
    this.bootstrap = true,
  });

  final ShellScreenBuilder screenBuilder;

  final ShellDestination initialDestination;

  /// Whether to reopen the last workspace and check the connection on first frame (the Swift
  /// `RootView.task`). Tests turn it off so a shell can be pumped without spawning abctl.
  final bool bootstrap;

  /// Remembered across launches, under abgui's own keys.
  static const String widthKey = 'abgui.sidebarWidth';
  static const String collapsedKey = 'abgui.sidebarCollapsed';

  /// The Swift split view's `min: 190, ideal: 214`, widened at the bottom end: this sidebar has a
  /// status pip in the trailing edge that the Swift one did not, and "Enrolled Devices" has to fit
  /// beside it without becoming "Enrolled…".
  static const double minWidth = 176;
  static const double maxWidth = 400;
  static const double defaultWidth = 214;

  /// Icon-rail width. Wide enough for a 15px glyph, its 2px selection bar and the pip.
  static const double railWidth = 52;

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  /// The sidebar width, deliberately OUTSIDE `setState`. A drag produces a delta per frame; a
  /// `setState` per frame would rebuild this widget, and with it the context bar, the run strip,
  /// the status bar and every child of the stack. Only the one `SizedBox` listening to this
  /// notifier is rebuilt instead.
  final ValueNotifier<double> _width = ValueNotifier<double>(
    RootShell.defaultWidth,
  );

  final ShellStatusController _status = ShellStatusController();

  /// Screens the user has actually opened.
  ///
  /// An `IndexedStack` builds and lays out ALL of its children, not just the visible one, so
  /// handing it nineteen screens up front would mount nineteen screens at launch — and every one
  /// of them would start its load, against the tenant, before the user had clicked anything. An
  /// unvisited slot is therefore an empty box, and a screen enters the stack on first selection
  /// and stays for the session.
  final Set<ShellDestination> _visited = <ShellDestination>{};

  /// The built screens, held by identity.
  ///
  /// This is what makes an unrelated rebuild of the shell free: Flutter short-circuits
  /// `Element.updateChild` when the new widget is `identical` to the old one, so re-handing the
  /// same instances to the stack skips those subtrees entirely. Without the cache, every screen
  /// would rebuild on every sidebar drag frame and on every navigation.
  final Map<ShellDestination, Widget> _screens = <ShellDestination, Widget>{};

  late ShellDestination _selected;

  bool _collapsed = false;

  /// Set the moment the user drags or collapses. A restore that lands after that must not stomp
  /// it — the same rule `WorkspaceStore.restore` follows, for the same reason: remembering a
  /// preference is a convenience, and it must never overrule a choice already made this session.
  bool _chromeTouched = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialDestination;
    _visited.add(_selected);
    _status.show(_selected.id);
    unawaited(_restoreChrome());
    if (widget.bootstrap) unawaited(_bootstrap());
  }

  @override
  void didUpdateWidget(RootShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different builder means different screens. Keeping the cache would leave the old ones on
    // screen forever, which in development reads as a hot reload that silently did nothing.
    if (oldWidget.screenBuilder != widget.screenBuilder) _screens.clear();
  }

  @override
  void dispose() {
    _width.dispose();
    _status.dispose();
    super.dispose();
  }

  /// Reopen the last workspace, then check the connection — in that order, and it matters.
  ///
  /// abctl resolves `gitops/` against its working directory, and the client is SCOPED by the
  /// workspace, so checking first would run `version`/`whoami` from wherever the app happened to
  /// be launched from and then rebuild the client underneath the answer.
  Future<void> _bootstrap() async {
    await ref.read(gitopsProvider.notifier).restoreWorkspace();
    await ref.read(connectionProvider.notifier).check();
  }

  Future<void> _restoreChrome() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      if (!mounted || _chromeTouched) return;
      final double? width = prefs.getDouble(RootShell.widthKey);
      final bool? collapsed = prefs.getBool(RootShell.collapsedKey);
      if (width != null) _width.value = _clamp(width);
      if (collapsed != null && collapsed != _collapsed) {
        setState(() => _collapsed = collapsed);
      }
    } catch (_) {
      // A preferences store that will not open leaves the defaults in place. The window is still
      // a window; there is nothing here worth interrupting the user about.
    }
  }

  /// Written on drag END and on toggle, never per frame: a drag would otherwise be a hundred
  /// writes to disk for one gesture.
  Future<void> _persistChrome() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      await prefs.setDouble(RootShell.widthKey, _width.value);
      await prefs.setBool(RootShell.collapsedKey, _collapsed);
    } catch (_) {
      // See _restoreChrome: failing to remember the layout must not fail the layout.
    }
  }

  static double _clamp(double value) =>
      math.min(RootShell.maxWidth, math.max(RootShell.minWidth, value));

  void _select(ShellDestination destination) {
    if (destination == _selected) return;
    setState(() {
      _selected = destination;
      _visited.add(destination);
    });
    // The status bar shows the VISIBLE screen's numbers. Every visited screen keeps reporting its
    // own into its own slot (see ShellStatusController), because a hidden screen in an
    // IndexedStack does not rebuild and so cannot be relied on to correct the bar later.
    _status.show(destination.id);
  }

  void _toggleCollapsed() {
    setState(() {
      _chromeTouched = true;
      _collapsed = !_collapsed;
    });
    unawaited(_persistChrome());
  }

  void _dragWidth(double delta) {
    _chromeTouched = true;
    _width.value = _clamp(_width.value + delta);
  }

  List<Widget> _children(BuildContext context) => ShellDestination.values
      .map(
        (ShellDestination destination) => _visited.contains(destination)
            ? _screens.putIfAbsent(
                destination,
                // Wrapped ONCE, inside the cache, so the slot is part of the cached instance and
                // a rebuild of the shell still hands the stack an `identical` child. It is what
                // lets a table several layers down report its counts into this screen's slot of
                // the status bar without every screen having to be told its own name.
                () => ShellSlot(
                  destinationId: destination.id,
                  child: widget.screenBuilder(context, destination),
                ),
              )
            // `const`, so every unvisited slot is the same canonical instance and the stack sees
            // an unchanged child rather than a new empty box each build.
            : const SizedBox.shrink(),
      )
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    // Built once per shell rebuild and handed to the ValueListenableBuilder as its `child`, so a
    // drag re-runs neither this constructor nor the nineteen rows under it.
    final Widget sidebar = Sidebar(
      selected: _selected,
      onSelect: _select,
      collapsed: _collapsed,
    );

    return ShellNavigation(
      go: _select,
      current: _selected,
      child: ShellStatusScope(
        controller: _status,
        // A Material at the root: every InkWell below (sidebar rows, toolbar buttons, the run
        // strip's command line) needs one to draw on, and one here means none of them has to
        // carry its own just to be tappable.
        child: Material(
          color: ab.canvas,
          child: Column(
            children: <Widget>[
              ContextBar(
                leading: ToolbarButton(
                  icon: abIcon('sidebar.left'),
                  label: _collapsed ? 'Expand sidebar' : 'Collapse sidebar',
                  tooltip: _collapsed
                      ? 'Show section names'
                      : 'Collapse the sidebar to an icon rail',
                  selected: _collapsed,
                  onPressed: _toggleCollapsed,
                ),
              ),
              // Above the split, below the context strip, and a SIBLING of both: with no abctl
              // there is nothing any screen can read, and each of the nineteen would otherwise
              // report that as its own empty pane — indistinguishable from an organization that
              // genuinely has no devices. It renders nothing at all when the binary is present.
              const AbctlMissingBanner(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (_collapsed)
                      SizedBox(width: RootShell.railWidth, child: sidebar)
                    else
                      ValueListenableBuilder<double>(
                        valueListenable: _width,
                        child: sidebar,
                        builder:
                            (
                              BuildContext context,
                              double width,
                              Widget? child,
                            ) => SizedBox(width: width, child: child),
                      ),
                    if (!_collapsed)
                      _ResizeHandle(
                        onDrag: _dragWidth,
                        onDragEnd: () => unawaited(_persistChrome()),
                        onDoubleTap: _toggleCollapsed,
                      ),
                    Expanded(
                      child: IndexedStack(
                        index: _selected.index,
                        // Tight constraints for the visible screen: a detail pane is expected to
                        // fill its column, and a table cannot virtualize without a bounded height.
                        sizing: StackFit.expand,
                        children: _children(context),
                      ),
                    ),
                  ],
                ),
              ),
              const RunStrip(),
              const StatusBar(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The draggable divider between the sidebar and the detail column.
///
/// Wider than the hairline it draws: a 1px hit target is a divider you fight with. The cursor
/// changes on hover, which is the only thing that says "this is draggable" before the user has
/// tried it, and a double-click collapses — the gesture every split view on every desktop has.
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.onDrag,
    required this.onDragEnd,
    required this.onDoubleTap,
  });

  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final AbColors ab = Theme.of(context).extension<AbColors>()!;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        // Opaque, so the drag is caught anywhere in the 5px strip rather than only on the pixel
        // the divider paints.
        behavior: HitTestBehavior.opaque,
        // `down`, not the default `start`. Flutter's drag recognizer needs 20 logical pixels of
        // movement before it claims the gesture, and under `start` those 20px are DISCARDED — the
        // divider would trail the cursor by that much for the rest of the drag and never catch up,
        // which on a resize handle reads as a divider that will not stick to the pointer.
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragUpdate: (DragUpdateDetails details) =>
            onDrag(details.delta.dx),
        onHorizontalDragEnd: (DragEndDetails _) => onDragEnd(),
        onDoubleTap: onDoubleTap,
        child: Semantics(
          label: 'Resize sidebar',
          child: SizedBox(
            width: 5,
            child: Center(child: Container(width: 1, color: ab.line)),
          ),
        ),
      ),
    );
  }
}
