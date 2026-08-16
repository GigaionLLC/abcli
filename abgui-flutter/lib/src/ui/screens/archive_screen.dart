// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The rollback browser: every pre-overwrite copy abctl filed under `gitops/archive/`, and the one
/// button that puts one back.
///
/// **This is the undo, and it is the screen someone reaches on their worst morning.** abctl
/// archives the live profile before every `replace` and every `delete`, so this table is the
/// record of what Apple Business used to have. Restoring runs `replace` with the archived body —
/// which archives the CURRENT live version first, so the rollback is itself rollbackable. That
/// fact is stated in the confirmation rather than left to be discovered, because an operator who
/// does not know it will not press the button, and an operator who does can act in the first
/// minute of an incident instead of the tenth.
///
/// **The listing reaches no tenant.** There is no abctl verb that enumerates the archive, so the
/// table is a filesystem walk — which means it keeps working when the connection is the thing that
/// is broken, which is exactly when it is needed. Only Restore goes near Apple Business.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/archive.dart';
import 'package:abgui/src/models/write_outcome.dart';
import 'package:abgui/src/platform/reveal_in_file_manager.dart';
import 'package:abgui/src/state/inventory_store.dart';
import 'package:abgui/src/state/load_token.dart';
import 'package:abgui/src/state/providers.dart';
import 'package:abgui/src/state/settings_store.dart';
import 'package:abgui/src/ui/dialogs/archived_file_dialog.dart';
import 'package:abgui/src/ui/screens/diagnostics_chrome.dart';
import 'package:abgui/src/ui/screens/inventory_chrome.dart';
import 'package:abgui/src/ui/sf_icons.dart';
import 'package:abgui/src/ui/theme.dart';
import 'package:abgui/src/ui/widgets/ab_table.dart';
import 'package:abgui/src/ui/widgets/ab_table_column.dart';
import 'package:abgui/src/ui/widgets/badge.dart';
import 'package:abgui/src/ui/widgets/empty_state.dart';
import 'package:abgui/src/ui/widgets/notice_banner.dart';
import 'package:abgui/src/ui/widgets/toolbar_button.dart';

/// Walk `<root>/gitops/archive/` in a worker isolate.
///
/// **A TOP-LEVEL function, and that is load-bearing rather than tidy.** `Isolate.run` SENDS the
/// closure, and a closure written inside a `State` method captures that method's context — which
/// links to `this`, to the `Element`, and from there to the whole widget tree and the test
/// binding's zone. Dart refuses to send that ("Illegal argument in isolate message: object is
/// unsendable — _CustomZone"), so the scan threw before it read a single directory and the table
/// was permanently empty. Declared out here, the closure holds one `String` and nothing else.
Future<List<ArchiveEntry>> _scanArchive(String root) =>
    Isolate.run(() => ArchiveScanner.scan(root));

class ArchiveScreen extends ConsumerStatefulWidget {
  const ArchiveScreen({super.key});

  @override
  ConsumerState<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends ConsumerState<ArchiveScreen> {
  /// One generation for the scan. Choosing a different workspace while the previous tree is
  /// still being walked must not have the old folder's entries land under the new folder's name —
  /// which on this screen would mean offering a rollback from the wrong tenant's repository.
  final LoadGeneration _scans = LoadGeneration('archive.scan');

  /// And one for the restore, separate for the reason `load_token.dart` spells out at length: a
  /// re-scan lands in the middle of every restore (the restore triggers one itself), and a shared
  /// counter would have the scan invalidate the write's token and leave `_restoring` stuck on with
  /// every control disabled.
  ///
  /// **Nothing invalidates it today, so the `token.isStale` checks in `_restore` are currently
  /// dead code — and they stay.** `_restore` guards on `_restoring`, so there is never a second
  /// restore to supersede the first, which is why `_restores.invalidate()` has no caller. The
  /// checks are the shape the next edit needs: the moment a workspace change (or a second
  /// restore) starts invalidating this, a completion that publishes over a newer one would offer
  /// a rollback from the wrong tenant's repository. Removing them would make that edit look
  /// finished when it is not. Audited and deliberately left; see also `_restoring`, which the
  /// `finally` does not clear precisely because only a stale run can reach the end without
  /// having cleared it itself.
  final LoadGeneration _restores = LoadGeneration('archive.restore');

  List<ArchiveEntry> _entries = const <ArchiveEntry>[];
  bool _scanning = false;

  /// Held as a PATH rather than as a row or an index: a re-scan rebuilds every [ArchiveEntry],
  /// and a git pull can delete one out from under the list between two scans.
  String? _selectedPath;

  String _filter = '';
  bool _revealFailed = false;

  /// The restore in flight, if any. Its own flag rather than a shared "busy": scanning the tree is
  /// a local read that may run at any time, and it must not disable Restore or vice versa.
  bool _restoring = false;

  /// Kills the abctl child if the screen goes away mid-restore. The write itself is not undone by
  /// this — abctl either PATCHed or it did not — but a process nobody is waiting on should not be
  /// holding a tenant connection open.
  CancelToken? _restoreCancel;

  /// The last restore's result, one or the other, never both. Rendered as banners above the table
  /// rather than as a floating overlay: the Swift original emitted its table and its error as two
  /// bare siblings into a slot that takes ONE view, so the error composited across the middle of
  /// the rows instead of sitting outside them — visible only after a write had already failed,
  /// which is the worst possible time to be reading a garbled screen.
  String? _restoreError;
  WriteOutcome? _restored;

  /// The workspace the current [_entries] were read from, so a rebuild that changes nothing else
  /// does not re-walk the tree.
  String? _scannedRoot;

  @override
  void initState() {
    super.initState();
    // After the frame: `ref.read` of the workspace is safe here, but the scan calls `setState`
    // from an async continuation, and starting it inside initState is the habit that eventually
    // lands one of those inside a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String? root = ref.read(workspaceProvider);
      if (root != null) unawaited(_scan(root));
    });
  }

  @override
  void dispose() {
    _restoreCancel?.cancel();
    super.dispose();
  }

  ArchiveEntry? get _selected {
    final String? path = _selectedPath;
    if (path == null) return null;
    for (final ArchiveEntry entry in _entries) {
      if (entry.filePath == path) return entry;
    }
    return null;
  }

  /// Walk `<root>/gitops/archive/`.
  ///
  /// **Off the main isolate.** [ArchiveScanner.scan] is synchronous `dart:io`: it lists one
  /// directory per archived configuration and reads a JSON sidecar for every file in them. On a
  /// repository with a year of history that is hundreds of opens and reads, and on the platform
  /// thread it is a visibly dropped frame — the same mistake as decoding a profile inside `build`.
  Future<void> _scan(String root) async {
    final LoadToken token = _scans.begin();
    setState(() {
      _scanning = true;
      _revealFailed = false;
    });
    final List<ArchiveEntry> found = await _scanArchive(root);
    if (!mounted || token.isStale) return;
    setState(() {
      _entries = found;
      _scannedRoot = root;
      _scanning = false;
      // Keep the selection if the file survived; otherwise drop it rather than sliding to a
      // neighbour, because Restore acting on a row the user did not pick is how a production
      // profile gets overwritten with the wrong version.
      final String? keep = _selectedPath;
      if (keep != null && !found.any((ArchiveEntry e) => e.filePath == keep)) {
        _selectedPath = null;
      }
    });
  }

  Future<void> _reveal() async {
    final ArchiveEntry? entry = _selected;
    if (entry == null) return;
    final bool ok = await RevealInFileManager.reveal(entry.filePath);
    if (!mounted) return;
    // Best effort: a desktop with no file manager must not raise a dialog over a path the user
    // can already read and select in the table.
    setState(() => _revealFailed = !ok);
  }

  // ---------------------------------------------------------------------------------------------
  // restore
  // ---------------------------------------------------------------------------------------------

  /// Why this entry cannot be restored, or null when it can.
  ///
  /// **The sidecar check is the load-bearing one.** `replace config <name>` resolves its argument
  /// against the live tenant, and without a readable sidecar [ArchiveEntry.configName] is the
  /// DIRECTORY SLUG rather than the configuration's real name. A slug that matches nothing fails
  /// loudly; a slug that happens to match a different configuration overwrites THAT one with these
  /// bytes. Refusing on an uncertain identity is the only safe reading of an unparseable sidecar.
  static String? _restoreBlockedReason(ArchiveEntry entry) {
    if (!entry.hasSidecar) {
      return 'This entry has no readable sidecar, so abgui only knows the folder it sits in — not '
          'the name Apple Business calls it. Restoring against a guess could overwrite a '
          'different configuration, so it is refused. View the file and restore it with '
          '`abctl replace config <name> -f <file>` once you know which one it is.';
    }
    if (entry.configName.trim().isEmpty) {
      return 'This entry\'s sidecar names no configuration, so there is nothing to address the '
          'replace at.';
    }
    return null;
  }

  /// Put an archived version back: read its bytes, confirm, then `replace`.
  ///
  /// The order matters. The SIZE is taken first so the confirmation can name it and so an
  /// unreadable file fails before anyone is asked to approve anything; the BODY is read only after
  /// the answer is yes, so a profile carrying a Wi-Fi password is not held in memory across a
  /// modal that might sit open for a minute.
  ///
  /// The bytes go to abctl as BYTES. A `.mobileconfig` may be a signed PKCS#7 envelope, and
  /// decoding it to a `String` and re-encoding — which the Swift original did — is a chance to
  /// change what Apple stores. `AbctlClient.createConfiguration` states the same rule for the same
  /// reason.
  Future<void> _restore() async {
    final ArchiveEntry? entry = _selected;
    if (entry == null || _restoring) return;

    final String? blocked = _restoreBlockedReason(entry);
    if (blocked != null) {
      setState(() {
        _restoreError = blocked;
        _restored = null;
      });
      return;
    }

    final File file = File(entry.filePath);
    final int bytes;
    try {
      bytes = await file.length();
    } catch (error) {
      setState(() {
        _restoreError =
            'Couldn\'t read the archived file at ${entry.filePath}: $error';
        _restored = null;
      });
      return;
    }
    if (bytes == 0) {
      setState(() {
        _restoreError =
            'The archived file is empty, so there is no version in it to restore. The bytes are '
            'gone; this row is only the record that something was archived here.';
        _restored = null;
      });
      return;
    }
    if (!mounted) return;

    final bool go = await RestoreArchiveDialog.confirm(
      context,
      entry: entry,
      bytes: bytes,
    );
    if (!go || !mounted) return;

    final List<int> xml;
    try {
      xml = await file.readAsBytes();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _restoreError =
            'Couldn\'t read the archived file at ${entry.filePath}: $error. Nothing was sent to '
            'Apple Business.';
        _restored = null;
      });
      return;
    }

    final LoadToken token = _restores.begin();
    final CancelToken cancel = CancelToken();
    _restoreCancel = cancel;
    setState(() {
      _restoring = true;
      _restoreError = null;
      _restored = null;
    });

    try {
      final WriteOutcome outcome = await ref
          .read(abctlClientProvider)
          .replaceConfiguration(
            // The SIDECAR's name. abctl resolves this against the tenant; the directory it sits
            // in is a slug and would address the wrong thing, which is what
            // [_restoreBlockedReason] refuses on.
            id: entry.configName,
            xml: xml,
            cancel: cancel,
          );
      if (!mounted || token.isStale) return;
      setState(() {
        _restored = outcome;
        _restoring = false;
      });
      // The proof of the promise the confirmation made: `replace` archived the version that was
      // live a second ago, so re-scanning puts it at the top of this table. Skipping the re-scan
      // would leave the user looking at a list that does not contain the thing they were just
      // told they could undo with.
      final String? root = ref.read(workspaceProvider);
      if (root != null) await _scan(root);
      // Re-checked after the walk: `ref` on a disposed `ConsumerState` throws, and the scan is an
      // await long enough for the user to have navigated away during it.
      if (!mounted) return;
      _refreshConfigurationsIfLoaded();
    } on AbctlCancelled {
      if (!mounted || token.isStale) return;
      // No message. The user asked for the stop — but abctl may have got as far as the PATCH, so
      // the next diff is the honest answer about what landed, and the note says so.
      setState(() {
        _restoring = false;
        _restoreError =
            'Restore cancelled. abctl may already have written to Apple Business — run Diff to '
            'see where the tenant actually is.';
      });
    } catch (error) {
      if (!mounted || token.isStale) return;
      setState(() {
        _restoring = false;
        _restoreError = loadErrorText(error);
      });
    } finally {
      if (identical(_restoreCancel, cancel)) _restoreCancel = null;
    }
  }

  /// Re-read the Configurations pane, but only if somebody has already loaded it.
  ///
  /// A restore changes the live profile's `updatedDateTime`, so a Configurations table already on
  /// screen is now stale in a way nothing about it shows. Loading a pane nobody has opened would
  /// be a tenant fetch nobody asked for, on a screen that has just finished one write — so the
  /// stamp decides.
  void _refreshConfigurationsIfLoaded() {
    final PaneStatus status = ref.read(
      paneStatusProvider(InventoryPane.configurations),
    );
    if (status.loadedAt == null) return;
    unawaited(
      ref.read(inventoryProvider.notifier).load(InventoryPane.configurations),
    );
  }

  // ---------------------------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final String? root = ref.watch(workspaceProvider);
    final AbDensity density = ref.watch(
      settingsProvider.select((Settings settings) => settings.density),
    );

    // The workspace is the screen's input, so a change to it is a re-scan — but scheduled, never
    // run from build: `_scan` publishes through setState.
    if (root != null && root != _scannedRoot && !_scanning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_scan(root));
      });
    }

    final ArchiveEntry? selected = _selected;
    final String? blocked = selected == null
        ? null
        : _restoreBlockedReason(selected);

    return InventoryScreenFrame(
      title: 'Archive',
      symbol: 'clock.arrow.circlepath',
      status: root == null
          ? null
          : '${_entries.length} archived ${_entries.length == 1 ? 'version' : 'versions'}',
      toolbar: <Widget>[
        if (root != null) ...<Widget>[
          ScreenSearchField(
            hint: 'Filter archive',
            onChanged: (String value) => setState(() => _filter = value),
          ),
          ToolbarButton(
            icon: abIcon('eye'),
            label: 'View',
            tooltip:
                'Show this archived profile exactly as it was before abctl overwrote or deleted '
                'it. Reads the local file; nothing is sent anywhere.',
            onPressed: selected == null
                ? null
                : () => unawaited(
                    ArchivedFileDialog.show(context, entry: selected),
                  ),
          ),
          ToolbarButton(
            icon: abIcon('arrow.uturn.backward'),
            label: 'Restore',
            weight: AbToolbarWeight.titled,
            // Names the consequence AND the safety net, because the safety net is what makes this
            // a decision somebody can actually take.
            tooltip: blocked != null
                ? 'Not available for this entry. $blocked'
                : 'Put this version back on Apple Business. abctl archives the CURRENT live '
                      'version first, so this is a reversible undo — you can restore your way '
                      'back with the row it creates. Asks for confirmation and shows the exact '
                      'command first.',
            onPressed: selected == null || _restoring || blocked != null
                ? null
                : () => unawaited(_restore()),
          ),
          ToolbarButton(
            icon: abIcon('folder'),
            label: 'Reveal',
            tooltip:
                'Show this archived profile in your file manager. It is the exact bytes that were '
                'live before abctl overwrote them.',
            onPressed: selected == null ? null : () => unawaited(_reveal()),
          ),
          ToolbarButton(
            icon: abIcon('arrow.clockwise'),
            label: 'Refresh',
            tooltip:
                'Re-scan gitops/archive/ on disk. Reads local files only — no tenant, no network.',
            onPressed: _scanning ? null : () => unawaited(_scan(root)),
          ),
        ],
      ],
      banner: root == null ? null : _banners(),
      child: root == null
          ? _noWorkspace()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: AbTable<ArchiveEntry>(
                    rows: _entries,
                    columns: _columns,
                    rowId: (ArchiveEntry entry) => entry.filePath,
                    filter: _filter,
                    density: density,
                    isLoading: _scanning,
                    selectionMode: AbSelectionMode.single,
                    // Double-click opens the VIEWER, never the restore. Activation is for reading;
                    // a write has to be chosen deliberately and confirmed.
                    onActivate: (ArchiveEntry entry) => unawaited(
                      ArchivedFileDialog.show(context, entry: entry),
                    ),
                    initialSortColumn: 'Archived',
                    semanticsLabel: 'Archived versions',
                    reportsStatus: true,
                    onSelectionChanged: (List<ArchiveEntry> picked) => setState(
                      () => _selectedPath = picked.isEmpty
                          ? null
                          : picked.first.filePath,
                    ),
                    emptyIcon: abIcon('clock.arrow.circlepath'),
                    emptyTitle: 'No archived versions',
                    emptyMessage:
                        'abctl files a copy of a live profile under gitops/archive/ before each '
                        'overwrite or delete. Nothing in this workspace has been overwritten yet.',
                    // No `error:`. `ArchiveScanner.scan` answers with an empty list for a tree
                    // that is missing or unreadable, because a fresh workspace has no archive
                    // directory and that is the normal state — not a failure to report.
                  ),
                ),
                if (_revealFailed)
                  Padding(
                    padding: const EdgeInsets.all(AbSpace.sm),
                    child: Text(
                      'Couldn\'t open a file manager here. The path is in the File column and is '
                      'selectable.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).extension<AbColors>()!.drift,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  /// The standing fact about this screen, then whatever the last restore has to say.
  ///
  /// A Column of full-width strips in the frame's own banner slot, which is between the title bar
  /// and the table and never over it — see [_restoreError] for the layout fault this arrangement
  /// is the fix for.
  Widget _banners() {
    final WriteOutcome? restored = _restored;
    final String? error = _restoreError;
    final String? treeWarning = restored?.treeWarning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        NoticeBanner(
          icon: abIcon('arrow.uturn.backward'),
          text: 'Reversible',
          detail:
              'Restoring replaces the live profile with the archived one, after archiving the '
              'version that is live now — so every rollback can itself be rolled back.',
        ),
        if (_restoring)
          NoticeBanner(
            icon: abIcon('clock'),
            tone: AbSeverity.drift,
            text: 'Restoring',
            detail:
                'abctl is archiving the current live version and writing the archived one back.',
          ),
        if (error != null)
          NoticeBanner(
            icon: abIcon('exclamationmark.triangle'),
            tone: AbSeverity.danger,
            text: 'Restore failed',
            detail: error,
            trailing: _DismissButton(
              onPressed: () => setState(() => _restoreError = null),
            ),
          ),
        if (restored != null)
          NoticeBanner(
            icon: abIcon(
              treeWarning == null ? 'checkmark.seal' : 'exclamationmark.circle',
            ),
            // A restore that reached Apple Business but not gitops/ is NOT a success: the tenant
            // and the tree now disagree, the next diff will show it as drift, and calling it green
            // is how that drift becomes a mystery. `WriteOutcome.treeWarning` is the one place
            // that distinction is computed.
            tone: treeWarning == null ? AbSeverity.ok : AbSeverity.drift,
            text: treeWarning == null
                ? 'Restored ${restored.name.isEmpty ? 'the profile' : restored.name}'
                : 'Restored on Apple Business only',
            detail:
                treeWarning ??
                'The version that was live has been archived — it is the newest row below, and '
                    'restoring it would put things back.',
            trailing: _DismissButton(
              onPressed: () => setState(() => _restored = null),
            ),
          ),
      ],
    );
  }

  Widget _noWorkspace() => EmptyState(
    icon: abIcon('folder.badge.questionmark'),
    title: 'No GitOps workspace',
    message:
        'Choose the folder that contains gitops/ in the strip at the top of the window. The '
        'archive lives inside it, at gitops/archive/.',
  );

  static final List<AbColumn<ArchiveEntry>> _columns = <AbColumn<ArchiveEntry>>[
    AbColumn<ArchiveEntry>(
      header: 'Configuration',
      // The SIDECAR's name, which is why the sidecar is read at all: the directory name is a
      // slug, and a slug is not what the profile is called in Apple Business. An entry whose
      // sidecar did not parse says so, because that is also the reason Restore is refused for it.
      value: (ArchiveEntry entry) =>
          entry.hasSidecar ? entry.configName : '${entry.configName} (?)',
      flex: 3,
      minWidth: 160,
    ),
    AbColumn<ArchiveEntry>(
      header: 'Archived',
      value: (ArchiveEntry entry) => entry.archivedAt,
      type: AbColumnType.date,
      width: 170,
    ),
    AbColumn<ArchiveEntry>(
      header: 'Reason',
      // Why abctl kept it: `overwrite`, `delete`. Rendered as a pill because it is a state
      // word scanned down a column, and neutral because neither is an error — an archive
      // entry is the system working.
      value: (ArchiveEntry entry) =>
          entry.reason.isEmpty ? 'unknown' : entry.reason,
      type: AbColumnType.badge,
      severity: (ArchiveEntry entry) =>
          entry.reason.isEmpty ? AbSeverity.drift : AbSeverity.neutral,
      width: 110,
    ),
    AbColumn<ArchiveEntry>(
      header: 'File',
      // The path relative to the workspace where possible. The absolute path is long enough
      // to swamp the row, and the part that identifies the file is the tail.
      value: (ArchiveEntry entry) => _fileName(entry.filePath),
      type: AbColumnType.mono,
      flex: 3,
      minWidth: 180,
    ),
  ];

  /// The file's own name. Both separators are checked because a workspace path on Windows can
  /// carry either — the same rule `ContextBar._leaf` follows.
  static String _fileName(String path) {
    final int slash = path.lastIndexOf(Platform.pathSeparator);
    final int alt = path.lastIndexOf('/');
    final int cut = slash > alt ? slash : alt;
    return cut < 0 ? path : path.substring(cut + 1);
  }
}

/// The X on a result banner.
///
/// A restore's outcome is a fact about a moment, not a standing property of the screen, so it has
/// to be dismissible — otherwise the last write's green tick sits above the table for the rest of
/// the session and starts reading as a claim about whatever is selected now.
class _DismissButton extends StatelessWidget {
  const _DismissButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ToolbarButton(
    icon: abIcon('xmark'),
    label: 'Dismiss',
    tooltip: 'Hide this message. It does not undo anything.',
    onPressed: onPressed,
  );
}
