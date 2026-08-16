// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

/// Show a file in the desktop's file manager, SELECTED — not merely open its folder.
///
/// This is hand-written rather than taken from a package on purpose. The only pub candidate
/// (`show_in_file_manager`) is at 0.0.2, is years stale, and has no Linux support at all, so
/// depending on it would mean owning the same three branches with an extra supply-chain hop and
/// someone else's release cadence in the way. Thirty lines we control is the better trade.
///
/// Every branch is best-effort by design: this is invoked from "Reveal in Finder"-style
/// affordances next to a log path that is ALSO displayed and copyable. A file manager that is
/// missing, sandboxed away, or simply not installed must never surface as an error dialog — the
/// user still has the path. [reveal] therefore returns whether it worked rather than throwing,
/// so a caller can quietly fall back to "copy path" instead of apologising.
abstract final class RevealInFileManager {
  /// Reveal [path] with the file itself selected. Returns false if nothing could be launched.
  ///
  /// [path] may be a file or a directory. A directory is opened rather than selected, because
  /// selecting a directory means selecting it inside its PARENT, which is rarely what the
  /// caller meant when they handed us a folder.
  static Future<bool> reveal(String path) async {
    final bool isDir = await FileSystemEntity.isDirectory(path);
    try {
      if (Platform.isMacOS) {
        // -R selects the item in a new-or-existing Finder window. Without it, `open` on a file
        // LAUNCHES the file — revealing a .mobileconfig would hand it to System Settings and
        // start an install flow, which is a genuinely bad outcome for a "show me this" button.
        return await _run(
          'open',
          isDir ? <String>[path] : <String>['-R', path],
        );
      }

      if (Platform.isWindows) {
        // The comma is part of the switch — `/select,<path>` — not a separator, and Explorer
        // silently ignores the argument if it is passed as a separate token. Explorer also
        // exits non-zero on success often enough that its exit code is not a usable signal, so
        // this branch reports success if the process merely started.
        if (isDir) {
          return await _run('explorer', <String>[path], trustExitCode: false);
        }
        return await _run('explorer', <String>[
          '/select,${_win(path)}',
        ], trustExitCode: false);
      }

      if (Platform.isLinux) {
        // Preferred: the freedesktop D-Bus interface, which is the only portable way to ask for
        // the file to be SELECTED. Implemented by Nautilus, Dolphin, Nemo and others.
        if (!isDir) {
          final bool ok = await _run('dbus-send', <String>[
            '--session',
            '--print-reply',
            '--dest=org.freedesktop.FileManager1',
            '/org/freedesktop/FileManager1',
            'org.freedesktop.FileManager1.ShowItems',
            'array:string:${Uri.file(path)}',
            'string:',
          ]);
          if (ok) return true;
        }
        // Fallback: open the containing directory. Loses the selection, but every desktop with
        // a file manager at all answers xdg-open, and a folder is far better than nothing.
        final String target = isDir ? path : (File(path).parent.path);
        return await _run('xdg-open', <String>[target]);
      }
    } on ProcessException {
      // The helper binary is not installed. Nothing to report — the caller shows the path.
      return false;
    }
    return false;
  }

  /// Windows wants backslashes; a Dart path built with `/` is accepted almost everywhere else
  /// but makes `/select,` fail silently, which looks like the button doing nothing.
  static String _win(String path) => path.replaceAll('/', r'\');

  static Future<bool> _run(
    String exe,
    List<String> args, {
    bool trustExitCode = true,
  }) async {
    final ProcessResult r = await Process.run(exe, args);
    return trustExitCode ? r.exitCode == 0 : true;
  }
}
