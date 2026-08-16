// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// The locator is the genuinely new part of the port — the Swift original had one candidate on
// one platform — so the bundle layouts are pinned here. `candidates` is pure, which is what
// lets a Windows CI machine verify the macOS layout and vice versa; getting that wrong is only
// discoverable at install time otherwise, on a machine that is not the developer's.

import 'dart:io';

import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/abctl_locator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bundle layouts', () {
    test(
      'macOS looks in Contents/Resources, then beside an unbundled build',
      () {
        expect(
          AbctlLocator.candidates(
            resolvedExecutable: '/Applications/abgui.app/Contents/MacOS/abgui',
            platform: AbctlPlatform.macOS,
          ),
          [
            '/Applications/abgui.app/Contents/Resources/abctl',
            '/Applications/abgui.app/Contents/MacOS/abctl',
          ],
        );
      },
    );

    test('Windows looks beside the exe and under data/', () {
      expect(
        AbctlLocator.candidates(
          resolvedExecutable: r'C:\Program Files\abgui\abgui.exe',
          platform: AbctlPlatform.windows,
        ),
        [
          r'C:\Program Files\abgui\abctl.exe',
          r'C:\Program Files\abgui\data\abctl.exe',
          r'C:\Program Files\abgui\data\flutter_assets\abctl.exe',
        ],
      );
    });

    test(
      'Windows accepts a forward-slashed path, which env vars often carry',
      () {
        expect(
          AbctlLocator.candidates(
            resolvedExecutable: 'C:/apps/abgui/abgui.exe',
            platform: AbctlPlatform.windows,
          ).first,
          r'C:/apps/abgui\abctl.exe',
        );
      },
    );

    test(
      'Linux looks beside the exe, in lib/, and in the installed ../lib',
      () {
        expect(
          AbctlLocator.candidates(
            resolvedExecutable: '/opt/abgui/abgui',
            platform: AbctlPlatform.linux,
          ),
          [
            '/opt/abgui/abctl',
            '/opt/abgui/lib/abctl',
            '/opt/lib/abctl',
            '/opt/abgui/data/flutter_assets/abctl',
          ],
        );
      },
    );

    test('the binary carries .exe on Windows and nowhere else', () {
      expect(AbctlPlatform.windows.binaryName, 'abctl.exe');
      expect(AbctlPlatform.macOS.binaryName, 'abctl');
      expect(AbctlPlatform.linux.binaryName, 'abctl');
    });
  });

  group('resolution', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('abgui_locator'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Temp cleanup is the OS's problem if it comes to that.
      }
    });

    test('the developer override wins over the bundle', () {
      final fake = _executableFile(dir, 'my-abctl');

      expect(
        AbctlLocator.resolve(
          environment: {AbctlLocator.envOverride: fake},
          resolvedExecutable: '/Applications/abgui.app/Contents/MacOS/abgui',
        ),
        fake,
      );
    });

    test(
      'a broken override fails loudly instead of silently using the bundled copy',
      () {
        // Falling back here would run the shipped binary while the developer believes they are
        // testing their local build — the single most confusing outcome available.
        expect(
          () => AbctlLocator.resolve(
            environment: {AbctlLocator.envOverride: '${dir.path}/typo-abctl'},
            resolvedExecutable: '/Applications/abgui.app/Contents/MacOS/abgui',
          ),
          throwsA(
            isA<AbctlMissingBinary>()
                .having(
                  (e) => e.message,
                  'message',
                  contains(AbctlLocator.envOverride),
                )
                .having((e) => e.message, 'message', contains('typo-abctl')),
          ),
        );
      },
    );

    test('an empty override is ignored, as an unset one is', () {
      // Shells export empty strings all the time (`export ABGUI_ABCTL=`), and treating that as
      // "the developer pointed me at nothing" would break the app for a stray line in a profile.
      expect(
        AbctlLocator.tryResolve(
          environment: {AbctlLocator.envOverride: ''},
          resolvedExecutable: '${dir.path}/abgui',
          platform: AbctlPlatform.linux,
        ),
        isNull,
      );
    });

    test('a missing binary reports every path it tried', () {
      expect(
        () => AbctlLocator.resolve(
          environment: const {},
          resolvedExecutable: '/opt/abgui/abgui',
          platform: AbctlPlatform.linux,
        ),
        throwsA(
          isA<AbctlMissingBinary>()
              .having((e) => e.searched, 'searched', hasLength(4))
              .having(
                (e) => e.message,
                'message',
                contains('/opt/abgui/lib/abctl'),
              ),
        ),
      );
    });

    test('a directory is not a binary', () {
      final sub = Directory('${dir.path}${Platform.pathSeparator}abctl')
        ..createSync();
      expect(AbctlLocator.isRunnable(sub.path), isFalse);
    });
  });
}

/// A real file the host OS agrees is executable: the POSIX check reads the mode, so the bit
/// has to actually be set.
String _executableFile(Directory dir, String name) {
  final path = '${dir.path}${Platform.pathSeparator}$name';
  File(path).writeAsStringSync('#!/bin/sh\nexit 0\n');
  if (!Platform.isWindows) {
    final result = Process.runSync('chmod', ['755', path]);
    expect(
      result.exitCode,
      0,
      reason: 'could not mark the test fixture executable',
    );
  }
  return path;
}
