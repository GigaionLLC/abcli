// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'json.dart';

/// One archived pre-overwrite live profile that abctl filed before an overwrite/delete,
/// under `<workspace>/gitops/archive/<name>/<ts>--<reason>.mobileconfig` (+ .json sidecar).
class ArchiveEntry {
  /// The real config name (from the sidecar), for restore. Falls back to the directory name,
  /// which is a SLUG — restoring against it would address the wrong config, so the sidecar is
  /// what the restore path reads.
  final String configName;
  final String reason;

  /// RFC3339.
  final String archivedAt;
  final String filePath;

  /// Whether the sidecar beside this profile parsed, and therefore whether [configName] is the
  /// real name or the directory SLUG it falls back to.
  ///
  /// **This is the gate on restore, not a display detail.** Restoring runs
  /// `replace config <configName>`, and abctl resolves that argument against the live tenant: a
  /// slug that happens to match nothing fails loudly, but a slug that happens to match a
  /// DIFFERENT configuration overwrites it with these bytes — a production profile destroyed by a
  /// corrupt JSON file nobody looked at. So the entry still LISTS without a sidecar (the archived
  /// profile is the only copy of the pre-overwrite bytes and hiding it would be worse), and the
  /// screen refuses to restore it.
  ///
  /// Defaults to false because false is the refusing direction: an entry built by some future
  /// path that forgot to say gets treated as unidentified rather than as safe.
  final bool hasSidecar;

  const ArchiveEntry({
    required this.configName,
    required this.reason,
    required this.archivedAt,
    required this.filePath,
    this.hasSidecar = false,
  });

  String get id => filePath;

  @override
  bool operator ==(Object other) =>
      other is ArchiveEntry &&
      other.configName == configName &&
      other.reason == reason &&
      other.archivedAt == archivedAt &&
      other.filePath == filePath &&
      other.hasSidecar == hasSidecar;

  @override
  int get hashCode =>
      Object.hash(configName, reason, archivedAt, filePath, hasSidecar);

  @override
  String toString() => 'ArchiveEntry($configName @ $archivedAt)';
}

/// The sidecar abctl writes next to each archived profile.
class _ArchiveSidecar {
  const _ArchiveSidecar(this.name, this.reason, this.archivedAt);

  final String name;
  final String reason;
  final String archivedAt;

  static _ArchiveSidecar? tryParse(String text) {
    try {
      final json = asJsonMap(jsonDecode(text));
      return _ArchiveSidecar(
        asStringOr(json, 'name', ''),
        asStringOr(json, 'reason', ''),
        asStringOr(json, 'archivedAt', ''),
      );
    } on FormatException {
      // Not JSON at all. The entry still lists from its filename — a corrupt sidecar must
      // not hide the archived profile it describes, which is the only copy of the old bytes.
      return null;
    }
  }
}

/// Reads the on-disk archive tree — pure filesystem, no abctl (there is no CLI command to list
/// the archive). Kept in the model layer so it is unit-testable against a temp tree.
abstract final class ArchiveScanner {
  static List<ArchiveEntry> scan(String root) {
    final archiveRoot = Directory('$root/gitops/archive');
    final List<FileSystemEntity> configDirs;
    try {
      configDirs = archiveRoot.listSync();
    } on FileSystemException {
      // No archive tree yet is the normal state of a fresh workspace, not an error.
      return const <ArchiveEntry>[];
    }
    final entries = <ArchiveEntry>[];
    for (final dir in configDirs) {
      if (dir is! Directory) {
        continue; // a stray file (e.g. .DS_Store) is not a config dir
      }
      final List<FileSystemEntity> files;
      try {
        files = dir.listSync();
      } on FileSystemException {
        continue;
      }
      for (final file in files) {
        if (file is! File || !file.path.endsWith('.mobileconfig')) continue;
        var name = _lastComponent(dir.path);
        var reason = '';
        var archivedAt = '';
        var hasSidecar = false;
        final sidecarPath =
            '${file.path.substring(0, file.path.length - '.mobileconfig'.length)}.json';
        final sidecarFile = File(sidecarPath);
        if (sidecarFile.existsSync()) {
          final side = _ArchiveSidecar.tryParse(sidecarFile.readAsStringSync());
          // A sidecar that parsed but names nothing is no better than one that did not parse:
          // `replace config ''` is not a command, and the fallback slug is not this profile's
          // name. Either way the entry is unidentified and restore refuses it.
          if (side != null && side.name.isNotEmpty) {
            name = side.name;
            reason = side.reason;
            archivedAt = side.archivedAt;
            hasSidecar = true;
          }
        }
        entries.add(
          ArchiveEntry(
            configName: name,
            reason: reason,
            archivedAt: archivedAt,
            filePath: file.path,
            hasSidecar: hasSidecar,
          ),
        );
      }
    }
    // Newest first. The stamps are RFC3339 UTC, which sorts correctly as text.
    entries.sort((a, b) => b.archivedAt.compareTo(a.archivedAt));
    return entries;
  }

  static String _lastComponent(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? trimmed : trimmed.substring(slash + 1);
  }
}
