// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

// Two properties are worth a test here, and they are the two that bite silently.
//
// The first is that the directory this hands back is one the app can actually WRITE — a getter
// that returns a plausible string for a path that does not exist reads as working right up
// until a support ticket needs the transcript that was never written.
//
// The second is that it degrades instead of throwing. `RunLog.begin` already answers null for
// "no log"; if the layer underneath it threw instead, a sync would fail because logging failed,
// which inverts the entire point of logging.
//
// Everything runs against an INJECTED environment rooted in a temp tree: a test that creates
// directories in the developer's real profile is a test nobody can run twice with confidence.

import 'dart:io';

import 'package:abgui/src/abctl/credential_store.dart';
import 'package:abgui/src/abctl/run_log.dart';
import 'package:abgui/src/platform/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abgui_paths');
    // The resolvers memoize successes process-wide; a stale entry would let one test's answer
    // satisfy the next test's expectation.
    AppPaths.resetForTesting();
  });
  tearDown(() {
    AppPaths.resetForTesting();
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // The OS owns its temp.
    }
  });

  /// An environment whose every root points inside [base]. XDG_* is deliberately absent so the
  /// Linux branch exercises its documented `~/.local/...` defaults rather than a value handed
  /// to it.
  Map<String, String> envUnder(String base) => <String, String>{
    'HOME': base,
    'USERPROFILE': base,
    'LOCALAPPDATA': base,
  };

  group('resolution on this platform', () {
    test(
      'the run log directory is absolute, created, and inside the temp tree',
      () async {
        final path = await AppPaths.runLogDirectory(
          environment: envUnder(root.path),
        );

        expect(path, isNotNull, reason: 'a writable temp root must resolve');
        expect(AppPaths.isAbsolutePath(path!), isTrue);
        expect(
          Directory(path).existsSync(),
          isTrue,
          reason: 'created on demand, not merely computed',
        );
        expect(
          path.startsWith(root.path),
          isTrue,
          reason:
              'the injected environment must not be ignored in favour of the '
              'real user profile',
        );
        // A file written here is the actual promise being made.
        final probe = File('$path${Platform.pathSeparator}probe.txt');
        probe.writeAsStringSync('ok');
        expect(probe.readAsStringSync(), 'ok');
      },
    );

    test('the application support directory is created too', () async {
      final path = await AppPaths.applicationSupportDirectory(
        environment: envUnder(root.path),
      );

      expect(path, isNotNull);
      expect(Directory(path!).existsSync(), isTrue);
      expect(path.startsWith(root.path), isTrue);
    });

    test(
      'a directory that cannot be created degrades to null, not an exception',
      () async {
        // A FILE where the root should be: `Directory.create` fails on every platform, standing
        // in for the read-only volume / sandbox denial this must survive in the field.
        final blocker = File('${root.path}${Platform.pathSeparator}not-a-dir')
          ..writeAsStringSync('');
        final environment = envUnder(blocker.path);

        await expectLater(
          AppPaths.runLogDirectory(environment: environment),
          completion(isNull),
        );
        await expectLater(
          AppPaths.applicationSupportDirectory(environment: environment),
          completion(isNull),
        );
      },
    );
  });

  group('layout', () {
    test(
      'the layout is delegated, so the writer and the viewer cannot disagree',
      () {
        // The reason this file computes nothing of its own. If either delegation is replaced by a
        // second copy of the three-branch rule, this fails.
        const environment = <String, String>{'HOME': '/Users/ada'};
        expect(
          AppPaths.runLogLayout(
            environment: environment,
            isWindows: false,
            isMacOS: true,
          ),
          RunLog.defaultDirectory(
            environment: environment,
            isWindows: false,
            isMacOS: true,
          ),
        );
        expect(
          AppPaths.keysLayout(
            environment: environment,
            isWindows: false,
            isMacOS: true,
          ),
          CredentialStore.keysDir(
            environment: environment,
            isWindows: false,
            isMacOS: true,
          ),
        );
        // And the data root is exactly the directory the key lives inside.
        expect(
          AppPaths.keysLayout(
            environment: environment,
            isWindows: false,
            isMacOS: true,
          ),
          startsWith(
            AppPaths.applicationSupportLayout(
              environment: environment,
              isWindows: false,
              isMacOS: true,
            ),
          ),
        );
      },
    );

    test('Windows resolves under LOCALAPPDATA, never a roaming profile', () {
      const environment = <String, String>{
        'LOCALAPPDATA': r'C:\Users\ada\AppData\Local',
        'APPDATA': r'C:\Users\ada\AppData\Roaming',
      };
      final support = AppPaths.applicationSupportLayout(
        environment: environment,
        isWindows: true,
        isMacOS: false,
      );
      final logs = AppPaths.runLogLayout(
        environment: environment,
        isWindows: true,
        isMacOS: false,
      );

      expect(support, r'C:\Users\ada\AppData\Local\abgui');
      expect(logs, r'C:\Users\ada\AppData\Local\abgui\logs');
      expect(support.contains('Roaming'), isFalse);
      expect(logs.contains('Roaming'), isFalse);
    });

    test('macOS and Linux follow their own conventions', () {
      expect(
        AppPaths.applicationSupportLayout(
          environment: const <String, String>{'HOME': '/Users/ada'},
          isWindows: false,
          isMacOS: true,
        ),
        '/Users/ada/Library/Application Support/abgui',
      );
      expect(
        AppPaths.runLogLayout(
          environment: const <String, String>{'HOME': '/Users/ada'},
          isWindows: false,
          isMacOS: true,
        ),
        '/Users/ada/Library/Logs/abgui',
      );
      expect(
        AppPaths.applicationSupportLayout(
          environment: const <String, String>{'HOME': '/home/ada'},
          isWindows: false,
          isMacOS: false,
        ),
        '/home/ada/.local/share/abgui',
      );
      expect(
        AppPaths.runLogLayout(
          environment: const <String, String>{'HOME': '/home/ada'},
          isWindows: false,
          isMacOS: false,
        ),
        '/home/ada/.local/state/abgui/logs',
      );
      expect(
        AppPaths.runLogLayout(
          environment: const <String, String>{
            'HOME': '/home/ada',
            'XDG_STATE_HOME': '/home/ada/.state',
          },
          isWindows: false,
          isMacOS: false,
        ),
        '/home/ada/.state/abgui/logs',
      );
    });
  });

  group('rootedness', () {
    // This is the switch that decides whether we trust the environment or ask path_provider, so
    // the Windows cases have to be right: a bare leading slash is drive-RELATIVE there, and
    // treating it as absolute would send a transcript to whatever drive the CWD happens to be on.
    test('Windows accepts a drive or a UNC root and nothing else', () {
      expect(AppPaths.isAbsolutePath(r'C:\Users\ada', isWindows: true), isTrue);
      expect(AppPaths.isAbsolutePath('C:/Users/ada', isWindows: true), isTrue);
      expect(
        AppPaths.isAbsolutePath(r'\\server\share\abgui', isWindows: true),
        isTrue,
      );
      expect(AppPaths.isAbsolutePath(r'\Users\ada', isWindows: true), isFalse);
      expect(
        AppPaths.isAbsolutePath(r'.\abgui\logs', isWindows: true),
        isFalse,
      );
      expect(AppPaths.isAbsolutePath('C:', isWindows: true), isFalse);
      expect(AppPaths.isAbsolutePath('', isWindows: true), isFalse);
    });

    test('POSIX accepts only a leading slash', () {
      expect(AppPaths.isAbsolutePath('/home/ada', isWindows: false), isTrue);
      expect(
        AppPaths.isAbsolutePath('./abgui/logs', isWindows: false),
        isFalse,
      );
      expect(AppPaths.isAbsolutePath('abgui/logs', isWindows: false), isFalse);
      expect(AppPaths.isAbsolutePath('', isWindows: false), isFalse);
    });
  });
}
