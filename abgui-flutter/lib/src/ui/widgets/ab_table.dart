// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Upward, and knowingly: `status_bar.dart` holds the shell's status CONTRACT (two inherited
// widgets and a value type) and none of its layout, and the table is the one widget in the app
// that can honour it — it is what knows how many rows survived the filter and how many of them
// the user picked. The alternative, an `onStatus` callback every screen wires by hand, is nine
// copies of the same four lines and eight chances to report the wrong pane's numbers.
import 'package:abgui/src/ui/shell/status_bar.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/mono_text.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';

/// How many rows may be selected at once.
enum AbSelectionMode {
  /// A pure display table. No cursor, no highlight, no keyboard selection.
  none,
  single,
  multiple,
}

/// The one table in the app.
///
/// **Why this exists rather than a platform table.** SwiftUI's `Table` (an `NSTableView`
/// underneath) is handed strings and knows nothing else about them, so every table in the Swift
/// app sorted versions lexicographically, showed serials in a proportional face, printed raw
/// ISO timestamps, and gave the user no way to see WHY a filtered row had survived. Those are
/// not styling complaints; each one is a way for an admin to misread their own tenant. A
/// hand-built table can be told what a column holds ([AbColumnType]) and then get alignment,
/// face, sort order, hover detail and search highlighting right in one place, for every screen.
///
/// **What it guarantees.**
///
///  * *Virtualized.* Rows are built on demand through `ListView.builder` with a fixed
///    `itemExtent`, so 5,000 devices cost the same as 50 and keyboard reveal is arithmetic
///    rather than a search.
///  * *Stable order.* Sorting is index-tiebroken (see [_recompute]). Rows with equal keys can
///    never swap places between rebuilds, which is what makes a table safe to read while a
///    refresh is landing.
///  * *Stable selection.* Selection is held as row IDS, never indices, so it survives a sort, a
///    filter and a refresh — the parent always acts on the rows the user actually picked.
///  * *States are internal.* Loading, failed and empty are decided here, so no screen
///    re-implements the three-way choice (and no screen forgets one and renders a blank pane).
///
/// It must be given a BOUNDED height — put it in an `Expanded`. An unbounded table cannot
/// virtualize, which would defeat the point.
class AbTable<T> extends StatefulWidget {
  const AbTable({
    super.key,
    required this.rows,
    required this.columns,
    required this.rowId,
    this.filter = '',
    this.density = AbDensity.comfortable,
    this.selectionMode = AbSelectionMode.multiple,
    this.onSelectionChanged,
    this.onActivate,
    this.severity,
    this.isLoading = false,
    this.error,
    this.emptyTitle = 'Nothing here',
    this.emptyMessage,
    this.emptyIcon = Icons.inbox_outlined,
    this.errorAction,
    this.initialSortColumn,
    this.semanticsLabel,
    this.autofocus = false,
    this.reportsStatus = false,
    this.doubleClickWindow = const Duration(milliseconds: 300),
  });

  /// Every row, unfiltered and unsorted. The table owns the derived view; the parent owns the
  /// data. Passing a pre-filtered list defeats the "N rows hidden" reporting below.
  final List<T> rows;

  final List<AbColumn<T>> columns;

  /// A stable identity per row. Used for selection, so a re-fetch that rebuilds every object
  /// does not silently clear (or worse, move) what the user had selected.
  final String Function(T row) rowId;

  /// The search box's text, owned by the parent. Rows survive if ANY column's display value
  /// contains it, case-insensitively — the same rule the Swift screens used — and the matching
  /// run is highlighted in-cell.
  final String filter;

  final AbDensity density;
  final AbSelectionMode selectionMode;

  /// Fires with the selected rows, in the source order of [rows], whenever selection changes.
  /// Never fires during a build.
  final void Function(List<T> rows)? onSelectionChanged;

  /// Double-click or Enter. Read-only by contract: this opens a detail view, it does not act on
  /// the tenant.
  final void Function(T row)? onActivate;

  /// The row's overall state, drawn as a 3px stripe down its left edge. The stripe is FORM, not
  /// just colour: a row's state stays visible in a screenshot, on a projector, and to a reader
  /// with no colour vision, none of which is true of a tinted background.
  final AbSeverity Function(T row)? severity;

  /// A load is in flight. With no rows yet this shows a spinner; with rows already on screen it
  /// shows a hairline progress bar UNDER the header and leaves the data readable — blanking a
  /// populated pane on every refresh is the single most-reported annoyance of the Swift app.
  final bool isLoading;

  /// The last load's failure, if any. With no rows this becomes the empty state; with stale
  /// rows still on screen it becomes a banner, so the user is never quietly reading old data.
  final String? error;

  final String emptyTitle;
  final String? emptyMessage;
  final IconData emptyIcon;

  /// Optional control offered on the failed-load state (typically Retry).
  final Widget? errorAction;

  /// Header of the column to sort by on first build. Null keeps the source order — which for
  /// live resources is the API's own order, and is meaningful.
  final String? initialSortColumn;

  /// What this table is showing, for screen readers: 'Devices', 'Blueprints'.
  final String? semanticsLabel;

  final bool autofocus;

  /// Whether this table fills the shell's status bar with "N rows · M selected".
  ///
  /// **Opt-IN, and false by default, because a screen can hold two tables.** The Command Log has
  /// its list of invocations and a per-verb timing panel; both are `AbTable`s, and if both
  /// reported they would take turns overwriting one slot and the bar would flicker between two
  /// unrelated numbers. Exactly one table per screen is the one the counts are ABOUT, and only
  /// the screen knows which — so the screen says so here.
  ///
  /// Reporting is a no-op outside the shell (no [ShellSlot], no [ShellStatusScope]), which is why
  /// every screen test that pumps a table on its own keeps working unchanged.
  final bool reportsStatus;

  /// How close two clicks must be to count as one double-click.
  ///
  /// A parameter only so tests can widen it: they assert that two taps activate a row, and on a
  /// loaded CI runner the gap between two synthetic taps can exceed any real-world interval —
  /// which would fail the test for a reason that has nothing to do with the behaviour.
  final Duration doubleClickWindow;

  @override
  State<AbTable<T>> createState() => AbTableState<T>();
}

/// Public only so widget tests can read the derived view directly instead of scraping the
/// rendered tree — order and selection are the two things most worth pinning, and asserting on
/// them through `RichText` spans would test the renderer rather than the logic.
class AbTableState<T> extends State<AbTable<T>> {
  /// The severity stripe's width, reserved on EVERY row (transparent when a row has no state)
  /// so that cells do not shift horizontally between rows.
  static const double _stripeWidth = 3;

  final ScrollController _vScroll = ScrollController();
  final ScrollController _hScroll = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'AbTable');

  /// The rows actually on screen: [AbTable.rows] filtered, then sorted. Recomputed only when an
  /// input that feeds it changes — NOT on every build, because selecting a row rebuilds this
  /// widget and re-sorting 5,000 rows on each click is a visible stall.
  List<T> _display = <T>[];

  String? _sortHeader;
  bool _ascending = true;

  final Set<String> _selected = <String>{};

  /// The keyboard cursor and the shift-extend anchor, as indices into [_display]. -1 means "no
  /// cursor yet"; the first arrow key lands on row 0 rather than jumping somewhere arbitrary.
  int _cursor = -1;
  int _anchor = -1;

  bool _hasFocus = false;
  String? _lastTapId;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The rows on screen right now, after the filter and the sort, in display order.
  ///
  /// PUBLIC on purpose, reachable through a `GlobalKey<AbTableState<T>>`: this is what an Export
  /// CSV must write. The Swift screens recomputed "filtered then sorted" a second time to build
  /// their export, and the two copies drifted — the CSV came out in a different order from the
  /// table it claimed to be a copy of. There is one derivation and this is it.
  List<T> get displayedRows => List<T>.unmodifiable(_display);

  @visibleForTesting
  Set<String> get selectedIds => Set<String>.unmodifiable(_selected);

  @visibleForTesting
  String? get sortColumn => _sortHeader;

  @visibleForTesting
  bool get sortAscending => _ascending;

  @override
  void initState() {
    super.initState();
    _sortHeader = widget.initialSortColumn;
    _recompute();
  }

  @override
  void didUpdateWidget(AbTable<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final inputsChanged =
        !identical(oldWidget.rows, widget.rows) ||
        oldWidget.filter != widget.filter ||
        _columnsDiffer(oldWidget.columns, widget.columns);
    if (inputsChanged) {
      _recompute();
      _pruneSelection();
    }
  }

  /// Have the columns actually changed shape?
  ///
  /// Compared by header and type rather than by list identity, because the natural way to write
  /// a screen is to build its column list inline in `build`. That produces a NEW list object on
  /// every parent rebuild, so an identity check would re-filter and re-sort the whole table
  /// every time anything on the screen twitched — which is precisely the cost the cached
  /// [_display] exists to avoid.
  bool _columnsDiffer(List<AbColumn<T>> before, List<AbColumn<T>> after) {
    if (identical(before, after)) return false;
    if (before.length != after.length) return true;
    for (var i = 0; i < before.length; i++) {
      if (before[i].header != after[i].header ||
          before[i].type != after[i].type) {
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _vScroll.dispose();
    _hScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------------------
  // Derived view
  // ---------------------------------------------------------------------------------------

  /// Rebuild [_display] from the inputs.
  ///
  /// The sort is performed over INDICES with the original index as the final tiebreak, which
  /// buys two things `List.sort` alone does not. Dart's sort is introsort and therefore not
  /// stable, so equal keys would otherwise land in an order that depends on the input length
  /// and could change between two rebuilds of identical data — a table where rows silently swap
  /// places while you read them. The tiebreak also gives descending order a defensible meaning:
  /// it reverses the KEYS, not the equal-key groups, so flipping direction twice returns
  /// exactly the arrangement you started from.
  void _recompute() {
    final needle = widget.filter.trim().toLowerCase();
    var rows = widget.rows;

    if (needle.isNotEmpty) {
      rows = <T>[
        for (final T row in rows)
          if (_matches(row, needle)) row,
      ];
    }

    final header = _sortHeader;
    if (header != null) {
      AbColumn<T>? column;
      for (final AbColumn<T> candidate in widget.columns) {
        if (candidate.header == header) {
          column = candidate;
          break;
        }
      }
      if (column != null && column.sortable) {
        final sorted = column;
        final order = List<int>.generate(rows.length, (int i) => i);
        final source = rows;
        order.sort((int x, int y) {
          final result = sorted.compareRows(source[x], source[y]);
          if (result != 0) return _ascending ? result : -result;
          return x - y;
        });
        rows = <T>[for (final int i in order) source[i]];
      }
    }

    _display = rows;
    // A shorter list must not leave the cursor pointing past the end; -1 when empty so the next
    // arrow key starts from the top again.
    if (_cursor >= _display.length) _cursor = _display.length - 1;
    if (_anchor >= _display.length) _anchor = _cursor;
  }

  bool _matches(T row, String needle) {
    for (final AbColumn<T> column in widget.columns) {
      if (column.value(row).toLowerCase().contains(needle)) return true;
    }
    return false;
  }

  /// Drop selected ids that no longer exist in the source.
  ///
  /// A refresh that removes a device must not leave the parent holding its id: the parent's
  /// next action would name a row that is gone. The notification is deferred to after the frame
  /// because this runs inside `didUpdateWidget`, and calling back into a parent's `setState`
  /// mid-build is a framework error.
  void _pruneSelection() {
    if (_selected.isEmpty) return;
    final live = <String>{for (final T row in widget.rows) widget.rowId(row)};
    final removed = _selected.length;
    _selected.retainAll(live);
    if (_selected.length == removed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _notifySelection();
    });
  }

  List<T> get _selectedRows => <T>[
    for (final T row in widget.rows)
      if (_selected.contains(widget.rowId(row))) row,
  ];

  void _notifySelection() => widget.onSelectionChanged?.call(_selectedRows);

  // ---------------------------------------------------------------------------------------
  // Sorting
  // ---------------------------------------------------------------------------------------

  void _toggleSort(AbColumn<T> column) {
    if (!column.sortable) return;
    setState(() {
      if (_sortHeader == column.header) {
        _ascending = !_ascending;
      } else {
        _sortHeader = column.header;
        _ascending = true;
      }
      _recompute();
    });
  }

  // ---------------------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------------------

  bool get _multi => widget.selectionMode == AbSelectionMode.multiple;

  /// A click on a row: select it, extend to it, toggle it, or — on the second click — open it.
  ///
  /// Double-clicks are detected here rather than through `GestureDetector.onDoubleTap`, which
  /// would make every `onTap` wait out the double-tap timeout before selecting. The Swift table
  /// selected the instant you pressed, and a 300ms lag on every click in a 5,000-row list is the
  /// kind of thing that makes a native app feel like a web page.
  void _handleTap(int index) {
    _focus.requestFocus();

    final keys = HardwareKeyboard.instance;
    // Read the modifiers from the keyboard rather than from the gesture: Flutter's tap callbacks
    // carry no modifier state, and this is the same source the Shortcuts below resolve against,
    // so click and keyboard can never disagree about whether shift is down.
    final extend = keys.isShiftPressed;
    final toggle = keys.isControlPressed || keys.isMetaPressed;

    final id = widget.rowId(_display[index]);
    final now = DateTime.now();
    // Matched on the row's ID, not its position: a sort or a refresh landing between the two
    // clicks moves rows around, and position alone would call two clicks on two DIFFERENT
    // devices a double-click and open the wrong detail sheet.
    //
    // A modified click is never an activation, however fast it repeats: cmd-clicking one row
    // twice means "select it, then deselect it", and opening a sheet on the second click would
    // both lose the deselection and cover the list.
    final isDoubleClick =
        id == _lastTapId &&
        !extend &&
        !toggle &&
        now.difference(_lastTapAt) <= widget.doubleClickWindow;
    _lastTapId = id;
    _lastTapAt = now;
    if (isDoubleClick) {
      widget.onActivate?.call(_display[index]);
      return;
    }

    // Activation stays available on a display-only table; only the selection below is gated.
    if (widget.selectionMode == AbSelectionMode.none) return;

    setState(() {
      if (extend && _multi && _anchor >= 0) {
        _selectRange(_anchor, index);
      } else if (toggle && _multi) {
        final id = widget.rowId(_display[index]);
        if (!_selected.remove(id)) _selected.add(id);
        _anchor = index;
      } else {
        _selectOnly(index);
      }
      _cursor = index;
    });
    _notifySelection();
  }

  void _selectOnly(int index) {
    _selected
      ..clear()
      ..add(widget.rowId(_display[index]));
    _anchor = index;
  }

  /// Replace the selection with the inclusive range between two display positions.
  ///
  /// Replacing rather than adding is what makes shift-click predictable: dragging the far end
  /// of a range back and forth grows and SHRINKS it, instead of accumulating everything the
  /// pointer ever passed over.
  void _selectRange(int from, int to) {
    final low = math.min(from, to);
    final high = math.max(from, to);
    _selected.clear();
    for (var i = low; i <= high; i++) {
      _selected.add(widget.rowId(_display[i]));
    }
  }

  void _selectAll() {
    if (!_multi || _display.isEmpty) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(<String>[for (final T row in _display) widget.rowId(row)]);
      _anchor = 0;
      _cursor = _display.length - 1;
    });
    _notifySelection();
  }

  // ---------------------------------------------------------------------------------------
  // Keyboard
  // ---------------------------------------------------------------------------------------

  void _move(int delta, {required bool extend}) {
    if (_display.isEmpty || widget.selectionMode == AbSelectionMode.none) {
      return;
    }
    final start = _cursor < 0 ? (delta > 0 ? -1 : _display.length) : _cursor;
    _placeCursor((start + delta).clamp(0, _display.length - 1), extend: extend);
  }

  void _jump({required bool toEnd, required bool extend}) {
    if (_display.isEmpty || widget.selectionMode == AbSelectionMode.none) {
      return;
    }
    _placeCursor(toEnd ? _display.length - 1 : 0, extend: extend);
  }

  void _placeCursor(int index, {required bool extend}) {
    setState(() {
      _cursor = index;
      if (extend && _multi && _anchor >= 0) {
        _selectRange(_anchor, index);
      } else {
        _selectOnly(index);
      }
    });
    _revealRow(index);
    _notifySelection();
  }

  /// Scroll the cursor back into view.
  ///
  /// Exact arithmetic rather than `Scrollable.ensureVisible`, because with a fixed `itemExtent`
  /// the offset of any row is known — including rows that are not built yet, which is precisely
  /// the case that matters when holding the down arrow through a long list. Jumps rather than
  /// animates: an animated scroll started every 30ms of key repeat fights itself.
  void _revealRow(int index) {
    if (!_vScroll.hasClients) return;
    final position = _vScroll.position;
    final rowHeight = widget.density.rowHeight;
    final top = index * rowHeight;
    final bottom = top + rowHeight;
    final double target;
    if (top < position.pixels) {
      target = top;
    } else if (bottom > position.pixels + position.viewportDimension) {
      target = bottom - position.viewportDimension;
    } else {
      return;
    }
    _vScroll.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  late final Map<ShortcutActivator, Intent>
  _shortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.arrowDown): const _MoveRowIntent(
      1,
    ),
    const SingleActivator(LogicalKeyboardKey.arrowUp): const _MoveRowIntent(-1),
    const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true):
        const _MoveRowIntent(1, extend: true),
    const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true):
        const _MoveRowIntent(-1, extend: true),
    const SingleActivator(LogicalKeyboardKey.home): const _JumpRowIntent(
      toEnd: false,
    ),
    const SingleActivator(LogicalKeyboardKey.end): const _JumpRowIntent(
      toEnd: true,
    ),
    const SingleActivator(LogicalKeyboardKey.home, shift: true):
        const _JumpRowIntent(toEnd: false, extend: true),
    const SingleActivator(LogicalKeyboardKey.end, shift: true):
        const _JumpRowIntent(toEnd: true, extend: true),
    // Both modifiers are bound rather than branching on the platform: this app ships on
    // macOS, Windows and Linux from one build, and a wrong guess here is an accessibility
    // regression nobody notices until a user reports "select all does nothing".
    const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
        const _SelectAllRowsIntent(),
    const SingleActivator(LogicalKeyboardKey.keyA, control: true):
        const _SelectAllRowsIntent(),
    const SingleActivator(LogicalKeyboardKey.enter): const _OpenRowIntent(),
  };

  late final Map<Type, Action<Intent>> _actions = <Type, Action<Intent>>{
    _MoveRowIntent: CallbackAction<_MoveRowIntent>(
      onInvoke: (_MoveRowIntent intent) {
        _move(intent.delta, extend: intent.extend);
        return null;
      },
    ),
    _JumpRowIntent: CallbackAction<_JumpRowIntent>(
      onInvoke: (_JumpRowIntent intent) {
        _jump(toEnd: intent.toEnd, extend: intent.extend);
        return null;
      },
    ),
    _SelectAllRowsIntent: CallbackAction<_SelectAllRowsIntent>(
      onInvoke: (_) {
        _selectAll();
        return null;
      },
    ),
    _OpenRowIntent: CallbackAction<_OpenRowIntent>(
      onInvoke: (_) {
        if (_cursor >= 0 && _cursor < _display.length) {
          widget.onActivate?.call(_display[_cursor]);
        }
        return null;
      },
    ),
  };

  // ---------------------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------------------

  /// Resolve every column to a concrete width.
  ///
  /// Concrete widths — not `Expanded` — because the header and the rows are separate widget
  /// subtrees, and any layout rule applied twice is a rule that can be applied differently
  /// twice. Computing the list once and handing the same numbers to both makes header/body
  /// misalignment structurally impossible rather than merely unlikely.
  List<double> _columnWidths(double available) {
    final columns = widget.columns;
    final usable = math.max(0.0, available - _stripeWidth);
    var fixed = 0.0;
    var totalFlex = 0;
    for (final AbColumn<T> column in columns) {
      if (column.width != null) {
        fixed += column.width!;
      } else {
        totalFlex += column.flex;
      }
    }
    final free = math.max(0.0, usable - fixed);
    return <double>[
      for (final AbColumn<T> column in columns)
        if (column.width != null)
          column.width!
        else
          math.max(
            column.minWidth,
            totalFlex == 0 ? 0.0 : free * column.flex / totalFlex,
          ),
    ];
  }

  /// Fill the shell's status bar with what this table is showing.
  ///
  /// Called from `build`, which is safe and deliberate: [ShellStatusController.report] defers its
  /// notification past the end of the frame precisely so the counts can be stated where they are
  /// known, and it drops a report that changes nothing — so a rebuild that did not move the
  /// numbers costs one map lookup and no repaint.
  ///
  /// `selectedCount` is null for a display-only table. "0 selected" on a table that can never
  /// have a selection is noise that never changes.
  void _reportStatus(BuildContext context) {
    final String? id = ShellSlot.idOf(context);
    if (id == null) return;
    ShellStatusScope.maybeOf(context)?.report(
      id,
      ShellStatus(
        rowCount: _display.length,
        selectedCount: widget.selectionMode == AbSelectionMode.none
            ? null
            : _selected.length,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ab = Theme.of(context).extension<AbColors>()!;
    final hasRows = _display.isNotEmpty;
    final staleError = widget.error != null && widget.rows.isNotEmpty;
    if (widget.reportsStatus) _reportStatus(context);

    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: _actions,
        child: Focus(
          focusNode: _focus,
          autofocus: widget.autofocus,
          onFocusChange: (bool value) => setState(() => _hasFocus = value),
          child: Semantics(
            container: true,
            label: widget.semanticsLabel == null
                ? '${_display.length} rows'
                : '${widget.semanticsLabel}, ${_display.length} rows',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (staleError)
                  NoticeBanner(
                    tone: AbSeverity.danger,
                    icon: Icons.warning_amber_rounded,
                    text: 'Showing the last data that loaded',
                    detail: widget.error,
                    trailing: widget.errorAction,
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      final widths = _columnWidths(constraints.maxWidth);
                      var content = _stripeWidth;
                      for (final double w in widths) {
                        content += w;
                      }
                      // Half a pixel of slack: floating-point width maths otherwise decides a
                      // table is 0.0000001px too wide and shows a scrollbar for nothing.
                      final overflows = content > constraints.maxWidth + 0.5;
                      final contentWidth = math.max(
                        content,
                        constraints.maxWidth,
                      );

                      // Header and body live inside ONE horizontal viewport, so a table too
                      // narrow for its columns scrolls sideways with its header still attached.
                      // Two synchronised scroll controllers would be the alternative, and
                      // keeping two positions in step is a well-known source of drift.
                      final Widget scroller = SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        controller: _hScroll,
                        // Nothing to reach sideways when there are no rows, so the empty state
                        // cannot be scrolled off the screen it is trying to explain.
                        physics: overflows && hasRows
                            ? null
                            : const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: contentWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _header(ab, widths),
                              _progressRule(ab),
                              Expanded(
                                child: hasRows
                                    ? _rowList(ab, widths)
                                    : Align(
                                        // The empty state is centred on the VIEWPORT, not on the
                                        // (possibly much wider) column content. Centred on the
                                        // content, a narrow window showing a wide table would put
                                        // "No devices" somewhere off to the right of the screen —
                                        // an explanation nobody can read is not an explanation.
                                        alignment: Alignment.topLeft,
                                        child: SizedBox(
                                          width: constraints.maxWidth,
                                          height: double.infinity,
                                          child: _stateView(),
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      );

                      return DecoratedBox(
                        decoration: BoxDecoration(color: ab.surface),
                        child: overflows
                            ? Scrollbar(
                                controller: _hScroll,
                                scrollbarOrientation:
                                    ScrollbarOrientation.bottom,
                                child: scroller,
                              )
                            : scroller,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The 2px rule under the header that a refresh runs in. It replaces the Swift behaviour of
  /// swapping the whole pane for a spinner, which threw away the rows the user was reading.
  Widget _progressRule(AbColors ab) {
    if (!widget.isLoading || _display.isEmpty) {
      return const SizedBox(height: 2);
    }
    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        minHeight: 2,
        backgroundColor: ab.raised,
        color: ab.accent,
      ),
    );
  }

  Widget _header(AbColors ab, List<double> widths) {
    final headerHeight = math.max(widget.density.rowHeight, 24.0);
    return Container(
      height: headerHeight,
      decoration: BoxDecoration(
        color: ab.raised,
        border: Border(bottom: BorderSide(color: ab.line)),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: _stripeWidth),
          for (var i = 0; i < widget.columns.length; i++)
            _headerCell(ab, widget.columns[i], widths[i]),
        ],
      ),
    );
  }

  Widget _headerCell(AbColors ab, AbColumn<T> column, double width) {
    final isSorted = _sortHeader == column.header;
    final label = Row(
      mainAxisAlignment: column.effectiveAlign == TextAlign.right
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: <Widget>[
        Flexible(
          child: Text(
            column.header.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AbType.label(
              context,
              color: isSorted ? ab.accent : ab.faint,
            ),
          ),
        ),
        // The direction marker appears on the sorted column ONLY. A row of arrows on every
        // header (one filled, the rest greyed) is how a table stops telling you which column it
        // is actually ordered by.
        if (isSorted) ...<Widget>[
          const SizedBox(width: 3),
          Icon(
            _ascending ? Icons.arrow_upward : Icons.arrow_downward,
            size: 11,
            color: ab.accent,
          ),
        ],
      ],
    );

    final cell = SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AbSpace.sm),
        child: Align(alignment: Alignment.centerLeft, child: label),
      ),
    );

    if (!column.sortable) {
      return Semantics(header: true, label: column.header, child: cell);
    }
    return Semantics(
      header: true,
      button: true,
      label: isSorted
          ? '${column.header}, sorted ${_ascending ? 'ascending' : 'descending'}'
          : '${column.header}, not sorted',
      excludeSemantics: true,
      child: Tooltip(
        message: isSorted
            ? 'Sort by ${column.header} (${_ascending ? 'descending' : 'ascending'})'
            : 'Sort by ${column.header}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleSort(column),
            child: cell,
          ),
        ),
      ),
    );
  }

  Widget _rowList(AbColors ab, List<double> widths) {
    final rowHeight = widget.density.rowHeight;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Only claim a scrollbar when there is something to scroll: the app theme pins
        // `thumbVisibility`, so an always-on thumb filling the whole track would otherwise sit
        // beside a three-row table looking like a broken control.
        final scrolls = _display.length * rowHeight > constraints.maxHeight;
        final list = ListView.builder(
          controller: _vScroll,
          // A fixed extent is what makes 5,000 rows cheap: the viewport can compute which rows
          // it needs instead of measuring its way down the list, and [_revealRow] can turn a row
          // index into a scroll offset without building anything.
          itemExtent: rowHeight,
          itemCount: _display.length,
          physics: scrolls ? null : const NeverScrollableScrollPhysics(),
          itemBuilder: (BuildContext context, int index) =>
              _row(ab, index, rowHeight, widths),
        );
        return scrolls
            ? Scrollbar(controller: _vScroll, child: list)
            : ClipRect(child: list);
      },
    );
  }

  Widget _row(AbColors ab, int index, double rowHeight, List<double> widths) {
    final row = _display[index];
    final id = widget.rowId(row);
    final selected = _selected.contains(id);
    final isCursor = index == _cursor;
    final severity = widget.severity?.call(row) ?? AbSeverity.neutral;

    return _AbTableRow(
      key: ValueKey<String>(id),
      height: rowHeight,
      selected: selected,
      cursor: isCursor && _hasFocus,
      selectable: widget.selectionMode != AbSelectionMode.none,
      stripe: severity == AbSeverity.neutral
          ? Colors.transparent
          : severity.ink(ab),
      stripeWidth: _stripeWidth,
      onTap: () => _handleTap(index),
      semanticsLabel: _rowSemantics(row, index, severity),
      selectedForSemantics: selected,
      colors: ab,
      // The SAME width list the header was laid out with, threaded through rather than
      // recomputed: two derivations of one number are two chances for the header to sit a pixel
      // off the column beneath it.
      widths: widths,
      children: <Widget>[
        for (var i = 0; i < widget.columns.length; i++)
          _cell(ab, widget.columns[i], row, i == 0),
      ],
    );
  }

  String _rowSemantics(T row, int index, AbSeverity severity) {
    final buffer = StringBuffer('Row ${index + 1} of ${_display.length}');
    for (final AbColumn<T> column in widget.columns) {
      buffer.write(', ${column.header} ${column.value(row)}');
    }
    // The stripe is a colour; this is the same fact in words. macOS VoiceOver support in
    // Flutter is thin, and a state carried only by a 3px bar is a state a screen reader user
    // does not have at all.
    if (severity != AbSeverity.neutral) {
      buffer.write(', ${severity.spokenName}');
    }
    return buffer.toString();
  }

  Widget _cell(AbColors ab, AbColumn<T> column, T row, bool isPrimary) {
    final text = column.value(row);
    final size = widget.density.fontSize;
    // The first column is the row's name — the thing you scan down. It gets the primary reading
    // colour and the rest get [AbColors.dim], so a wide table still has one obvious column to
    // read rather than eight competing ones.
    final color = isPrimary ? ab.text : ab.dim;
    final filter = widget.filter;

    final Widget child;
    switch (column.type) {
      case AbColumnType.text:
        child = AbCellText(
          text,
          highlight: filter,
          size: size,
          color: color,
          align: column.effectiveAlign,
          weight: isPrimary ? FontWeight.w500 : null,
        );
      case AbColumnType.mono:
      case AbColumnType.number:
        child = MonoText(
          text,
          highlight: filter,
          size: size - 0.5,
          color: color,
          align: column.effectiveAlign,
        );
      case AbColumnType.date:
        child = _dateCell(text, size, color, filter);
      case AbColumnType.badge:
        child = AbBadge(
          label: text,
          severity: column.severity?.call(row) ?? AbSeverity.neutral,
          highlight: filter,
          fontSize: size - 1.5,
        );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbSpace.sm),
      child: Align(
        alignment: column.effectiveAlign == TextAlign.right
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: child,
      ),
    );
  }

  Widget _dateCell(String raw, double size, Color color, String filter) {
    final parsed = DateTime.tryParse(raw.trim());
    if (parsed == null) {
      // Unparseable timestamps are shown VERBATIM. Apple has emitted more than one date shape
      // over the API's life, and printing "—" for a value that is plainly there is how a
      // support conversation starts with the wrong premise.
      return MonoText(raw, highlight: filter, size: size - 0.5, color: color);
    }
    // The relative reading is the one that answers "is this recent?" at a glance; the exact
    // instant is one hover away, and never lost.
    return Tooltip(
      message: AbRelativeTime.absolute(parsed),
      child: MonoText(
        AbRelativeTime.short(parsed),
        // A relative string cannot contain the raw timestamp the user searched for, so the
        // in-cell highlight would silently do nothing. Highlighting the whole cell instead
        // keeps the promise that a filtered row shows WHY it survived.
        highlight:
            filter.trim().isNotEmpty &&
                raw.toLowerCase().contains(filter.trim().toLowerCase())
            ? AbRelativeTime.short(parsed)
            : '',
        size: size - 0.5,
        color: color,
      ),
    );
  }

  Widget _stateView() {
    if (widget.isLoading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final error = widget.error;
    if (error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Couldn\'t load',
        message: error,
        tone: AbSeverity.danger,
        action: widget.errorAction,
      );
    }
    if (widget.filter.trim().isNotEmpty && widget.rows.isNotEmpty) {
      final hidden = widget.rows.length;
      // Naming the count and the term is the difference between "there is nothing here" and
      // "your search is hiding everything" — the two situations a blank pane conflates.
      return EmptyState(
        icon: Icons.search_off,
        title: 'No matches',
        message:
            '${hidden == 1 ? '1 row is' : '$hidden rows are'} hidden by the '
            'filter "${widget.filter}".',
      );
    }
    return EmptyState(
      icon: widget.emptyIcon,
      title: widget.emptyTitle,
      message: widget.emptyMessage,
    );
  }
}

/// One row. Stateful ONLY to own its hover flag: hovering must repaint the row under the
/// pointer and nothing else, and a hover handled by the table would rebuild every visible row
/// on every pointer move across a 5,000-row list.
class _AbTableRow extends StatefulWidget {
  const _AbTableRow({
    super.key,
    required this.height,
    required this.selected,
    required this.cursor,
    required this.selectable,
    required this.stripe,
    required this.stripeWidth,
    required this.onTap,
    required this.semanticsLabel,
    required this.selectedForSemantics,
    required this.colors,
    required this.widths,
    required this.children,
  });

  final double height;
  final bool selected;
  final bool cursor;
  final bool selectable;
  final Color stripe;
  final double stripeWidth;
  final VoidCallback onTap;
  final String semanticsLabel;
  final bool selectedForSemantics;
  final AbColors colors;
  final List<Widget> children;
  final List<double> widths;

  @override
  State<_AbTableRow> createState() => _AbTableRowState();
}

class _AbTableRowState extends State<_AbTableRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ab = widget.colors;
    final Color? background;
    if (widget.selected) {
      background = ab.sunken;
    } else if (_hovered) {
      background = ab.raised.withValues(alpha: 0.55);
    } else {
      background = null;
    }

    return Semantics(
      selected: widget.selectedForSemantics,
      label: widget.semanticsLabel,
      // The cells' own text is already in the label, laid out as header/value pairs. Left in,
      // VoiceOver would read the row twice — once as a sentence and once as loose fragments.
      excludeSemantics: true,
      child: MouseRegion(
        cursor: widget.selectable
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: background,
              border: Border(bottom: BorderSide(color: ab.lineSoft)),
            ),
            // The keyboard cursor is an outline, not a fill: it has to stay distinct from
            // selection, which IS a fill, so "where am I" and "what did I pick" stay two
            // readable facts on a multi-selected list.
            //
            // It has to be a FOREGROUND decoration. A border in `decoration` is inset from the
            // box like padding, so the cursor row would hand its children 2px less width than
            // every other row — the columns under the cursor would shift by a pixel as it
            // moved, and the last column would overflow its own row. (Caught by the widget
            // tests, which fail on any overflow.)
            foregroundDecoration: widget.cursor
                ? BoxDecoration(border: Border.all(color: ab.accent))
                : null,
            child: Row(
              children: <Widget>[
                Container(width: widget.stripeWidth, color: widget.stripe),
                for (var i = 0; i < widget.children.length; i++)
                  SizedBox(
                    width: i < widget.widths.length ? widget.widths[i] : 0,
                    child: widget.children[i],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MoveRowIntent extends Intent {
  const _MoveRowIntent(this.delta, {this.extend = false});

  final int delta;
  final bool extend;
}

class _JumpRowIntent extends Intent {
  const _JumpRowIntent({required this.toEnd, this.extend = false});

  final bool toEnd;
  final bool extend;
}

class _SelectAllRowsIntent extends Intent {
  const _SelectAllRowsIntent();
}

class _OpenRowIntent extends Intent {
  const _OpenRowIntent();
}
