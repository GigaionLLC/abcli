// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:abgui/src/abctl/abctl_error.dart';
import 'package:abgui/src/abctl/command_formatter.dart';
import 'package:abgui/src/abctl/process_runner.dart';
import 'package:abgui/src/models/command_line_parser.dart';
import 'package:abgui/src/models/command_record.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'load_token.dart';
import 'providers.dart';

/// The typed console: an operator types an abctl command, abgui runs it with the connection and
/// the workspace already applied, and the whole transcript stays on screen.
///
/// The GUI will always cover less of abctl than abctl does. Rather than pretend otherwise this is
/// the escape hatch — with one boundary that the Swift original did not have.
///
/// **The console is READ-ONLY, and it stays that way in the release that turned the writes on.**
/// Every write in abgui is reached through a surface built around it — a plan counted by
/// consequence, a typed confirmation naming the tenant, a run log, a receipt rendered afterwards.
/// A text field has none of that, so a mutating verb typed here would be a second door past all
/// of it. The Swift app instead showed a confirmation dialog and ran the command; that is the
/// behaviour this port deliberately does not reproduce. The boundary is [ConsoleGuard], checked
/// BEFORE anything is spawned, and its refusals name the screen that does perform the verb.
///
/// The guard lives on the STORE, not on the screen. A disabled Run button is a UI convenience —
/// it can be bypassed by pressing Enter, by a future keyboard shortcut, or by any second caller
/// of [ConsoleStore.run] — whereas a refusal checked here is one every path goes through.
class ConsoleEntry {
  ConsoleEntry({
    required List<String> argv,
    this.stdout = '',
    this.stderr = '',
    this.exitCode,
    this.duration = Duration.zero,
    this.notRun,
    this.refused = false,
    String? id,
  }) : argv = CommandFormatter.redact(argv),
       id = id ?? CommandRecord.newId();

  /// Stable identity for the transcript row (and for the screen's "expanded" set, which must
  /// survive a rebuild that appends a newer entry above it).
  final String id;

  /// The argv that ran, REDACTED at construction exactly as `CommandRecord` does it — a typed
  /// `vpp assets --vpp-token …` must not leave the token sitting in a transcript with a copy
  /// button under it.
  final List<String> argv;

  /// abctl's two streams, kept apart. They carry different KINDS of thing — the machine payload
  /// on stdout, human narration on stderr — and merging them is how a JSON document becomes
  /// unparseable and a hundred progress lines become "the error".
  ///
  /// Both are clamped to [maxStreamBytes]; see [ConsoleStore.clamp].
  final String stdout;
  final String stderr;

  /// Null when abctl never ran (refused, failed to spawn, cancelled, timed out). Deliberately
  /// nullable rather than defaulted to 0: a default of zero reports "exit 0" for a command that
  /// never happened, which is indistinguishable from a successful run.
  final int? exitCode;

  final Duration duration;

  /// Why there is no exit code. Shown verbatim.
  final String? notRun;

  /// True when [notRun] is abgui's own read-only refusal rather than a failure. It is not an
  /// error and must not be coloured as one — the command was never attempted, and nothing on the
  /// tenant or on disk was touched.
  final bool refused;

  String get commandLine => CommandFormatter.line(argv);

  /// Exit 3 is abctl's "changes pending" — a normal answer from `diff --exit-on-diff`, not a
  /// failure. Colouring it red teaches people to ignore red.
  bool get isFailure {
    if (refused) return false;
    final code = exitCode;
    if (code == null) return true;
    return code != 0 && code != 3;
  }

  /// The one-line verdict shown beside the command.
  String get statusText {
    if (refused) return 'not run';
    final reason = notRun;
    if (reason != null) return 'did not run';
    final code = exitCode ?? 0;
    return '${code == 0 ? 'exit 0' : 'exit $code'} · ${DurationText.short(duration)}';
  }

  /// The copy form: the command, then everything it printed, then how it ended. One string,
  /// because what a person pastes into a ticket is the whole exchange and not a fragment of it.
  String get transcript {
    final parts = <String>['\$ $commandLine'];
    if (stdout.trim().isNotEmpty) parts.add(stdout.trimRight());
    if (stderr.trim().isNotEmpty) parts.add(stderr.trimRight());
    final reason = notRun;
    parts.add(reason == null ? '($statusText)' : '($statusText — $reason)');
    return parts.join('\n');
  }
}

/// The console's read-only boundary, as a function of argv.
///
/// It answers null for a command the console may run, and the sentence to show for one it may
/// not. Pure and static so it can be tested without a process, a provider or a widget — the same
/// reason `abctl_args.dart` imports nothing.
///
/// **This is no longer "abgui cannot write" — abgui writes, and that is exactly why the boundary
/// stays.** Every write in this app is reached through a surface that surrounds it with the
/// things a tenant write needs: a computed plan, counts by consequence, a typed confirmation
/// against the tenant's own name, a run log, and a receipt rendered afterwards
/// (`ApplyDialog`, `ConfigEditorDialog`, `MembershipDialog`, `AssignDialog`). A text field has
/// none of that. Letting `sync --apply --yes --prune` through here would not be *enabling* a
/// feature the app lacks; it would be a second, ungated door to the one operation the whole
/// screen above it exists to gate. So a refused verb is not "wait for a later release" — it is
/// "that write has a home, and this is not it", and every sentence below says which home.
///
/// **Why the list is built FROM [CommandLineParser.writeVerbs] rather than re-spelled.** That set
/// already exists and is already the app's answer to "does this argv write?"; a second, private
/// copy here would be a second thing to update when abctl grows a verb, and the copy that gets
/// forgotten is this one — the one standing between a typed command and a live tenant. Two verbs
/// are ADDED to it, both because they write something that set is not about: `adopt` writes the
/// workspace's blueprint manifests, and `seed` writes the whole `gitops/` tree from live state.
/// (`CommandLineParser.writeVerbs` describes writes to *Apple Business*; it is used elsewhere
/// only to warn, and its own doc says so.)
abstract final class ConsoleGuard {
  /// Workspace-writing verbs that [CommandLineParser.writeVerbs] does not list, because they
  /// change files rather than the tenant.
  static const Set<String> workspaceWriteVerbs = <String>{'adopt', 'seed'};

  /// `context` sub-verbs that rewrite `~/.abctl/contexts.yaml` — the operator's credential store.
  /// abgui never writes that file from any screen (see `settings_screen.dart` for why), and the
  /// console must not be the back door into the surface Settings declines to offer.
  static const Set<String> contextWriteSubVerbs = <String>{
    'set',
    'use',
    'delete',
    'remove',
    'rename',
  };

  /// Flags that exist ONLY to carry a write past a confirmation. Checked whatever the verb is:
  /// abctl gains verbs faster than abgui learns them, and a command that had to say `--yes` is
  /// self-describing about what it was going to do.
  static const Set<String> approvalFlags = <String>{'--apply', '--yes'};

  /// Every verb the console refuses outright.
  static Set<String> get blockedVerbs =>
      <String>{...CommandLineParser.writeVerbs, ...workspaceWriteVerbs}
        ..remove('sync'); // a bare `sync` is a dry run — see [refusal]

  /// The refusal sentence for [argv], or null if it may run.
  static String? refusal(List<String> argv) {
    if (argv.isEmpty) return null;
    final verb = argv.first.toLowerCase();

    // `sync` is the one verb whose meaning is decided by a flag: without `--apply` it is a dry
    // run that writes nothing (abctl's own `--dry-run`), which is a read like any other.
    if (verb == 'sync') {
      if (!argv.contains('--apply')) return null;
      return 'The console will not run `sync --apply`. It writes every pending change to Apple '
          'Business, and abgui runs it from the Diff screen instead — where the plan is counted '
          'by consequence, removals are stated separately, the tenant\'s name has to be typed, '
          'and abctl\'s per-item receipt is rendered afterwards. Open Diff and press Apply.';
    }

    if (verb == 'context' &&
        argv.length > 1 &&
        contextWriteSubVerbs.contains(argv[1].toLowerCase())) {
      return 'The console will not run `context ${argv[1]}`: it rewrites ~/.abctl/contexts.yaml, '
          'your saved connections. abgui reads that file and never writes it, from any screen — '
          'edit it with abctl in a terminal.';
    }

    if (blockedVerbs.contains(verb)) {
      final String where = switch (verb) {
        'create' ||
        'replace' ||
        'delete' => 'Configurations has New, Edit and Delete',
        'attach' ||
        'detach' ||
        'adopt' => 'Blueprints has Attach, Detach and Adopt',
        'assign' || 'unassign' => 'Devices has Assign',
        'seed' => 'Diff has Seed',
        _ => 'the screen that owns the object has the control',
      };
      return 'The console will not run `$verb`. That verb changes '
          '${workspaceWriteVerbs.contains(verb) ? 'your workspace tree' : 'Apple Business'}, and '
          'abgui runs it from a screen that can confirm it and show what came back: $where. '
          'Reads, `diff` and `validate` all work here.';
    }

    for (final String argument in argv) {
      if (approvalFlags.contains(argument.toLowerCase())) {
        return 'The console will not run `$argument`: it exists only to skip the confirmation '
            'before a write, and skipping a confirmation is the one thing a typed command must '
            'not be able to do here. Drop the flag to run the read half of this command, or use '
            'the screen that owns the write.';
      }
    }
    return null;
  }
}

/// The console's transcript, its history and whether something is in flight.
class ConsoleState {
  const ConsoleState({
    this.entries = const <ConsoleEntry>[],
    this.history = const <String>[],
    this.isRunning = false,
  });

  /// Oldest first, so the view scrolls the way a terminal does.
  final List<ConsoleEntry> entries;

  /// Command lines typed this session, oldest first, for up/down recall at the prompt.
  final List<String> history;

  final bool isRunning;

  ConsoleState copyWith({
    List<ConsoleEntry>? entries,
    List<String>? history,
    bool? isRunning,
  }) => ConsoleState(
    entries: entries ?? this.entries,
    history: history ?? this.history,
    isRunning: isRunning ?? this.isRunning,
  );

  /// Identity on the lists, matching `CommandLog`: both are replaced wholesale and never mutated,
  /// so identity IS value equality — and an element-wise compare would run on every notification
  /// over entries that can hold a couple of hundred kilobytes of output each.
  @override
  bool operator ==(Object other) =>
      other is ConsoleState &&
      identical(other.entries, entries) &&
      identical(other.history, history) &&
      other.isRunning == isRunning;

  @override
  int get hashCode => Object.hash(
    identityHashCode(entries),
    identityHashCode(history),
    isRunning,
  );
}

/// Runs typed commands through the ordinary client, so a typed command carries the same
/// `--context` and the same workspace cwd as every button in the app.
class ConsoleStore extends Notifier<ConsoleState> {
  /// Same cap as the Swift original. The interesting entries are the recent ones, and the
  /// Command Log keeps the argv of everything anyway.
  static const int maxEntries = 100;

  /// How much of one stream is kept, per entry.
  ///
  /// The Swift version kept everything, which was survivable on one screen and is not here: `get
  /// devices -o json` on a large tenant is tens of megabytes, and a hundred of those is the whole
  /// process. The clamp is on the STORE rather than on the view because it is a memory bound, not
  /// a layout one — and the marker says plainly that the copy button now hands back less than
  /// abctl printed, which is the sort of thing a person must never discover from a truncated
  /// bug report.
  static const int maxStreamBytes = 200 * 1024;

  /// Its own generation, so a command started after a cancel cannot be un-published by the run it
  /// replaced. One console runs one command at a time, but "one at a time" is enforced by a flag
  /// that a cancel clears, and that is exactly the window a stale completion would land in.
  final LoadGeneration _runs = LoadGeneration('console.run');

  /// The in-flight command's cancel token. A field rather than part of [ConsoleState]: it is a
  /// live object with identity, not a value, and putting it in immutable state would mean a
  /// rebuild every time it changed hands.
  CancelToken? _active;

  @override
  ConsoleState build() => const ConsoleState();

  bool get isRunning => state.isRunning;

  /// Run one typed command line. Returns false when there was nothing to run.
  ///
  /// A non-zero exit is DATA here, never an exception: the console's whole job is to show what
  /// abctl said, and mapping exit 1 onto a thrown error would replace the tool's own stderr with
  /// abgui's paraphrase of it. See `AbctlClient.console`, which is the one client method that
  /// deliberately skips `checkExit`.
  Future<bool> run(String line) async {
    if (state.isRunning) return false;
    final argv = CommandLineParser.tokenize(line);
    if (argv.isEmpty) return false;

    // **Recalled REDACTED, not as typed.** `ConsoleEntry`'s constructor already runs
    // `CommandFormatter.redact` over argv, so the transcript row for `vpp assets --vpp-token
    // eyJ…` reads `--vpp-token ****` and the copy button under it copies that. History was the
    // hole: it stored the raw line, and the up arrow rendered the token straight back into the
    // text field — on whatever screen share or support screenshot was running. Re-tokenizing and
    // re-rendering through the same redactor closes it with the rule that already exists rather
    // than a second copy of it.
    //
    // The cost is that recalling such a command recalls `****` and abctl rejects it, which is the
    // safe direction: a token that has to be pasted again is an inconvenience, and one that was
    // silently reused out of a buffer nobody could see is a leak.
    final typed = CommandFormatter.redact(
      argv,
    ).map(CommandFormatter.quote).join(' ');
    // Consecutive duplicates are not recorded, the way a shell's history behaves: re-running the
    // same command three times while watching a tenant settle should not need three presses of
    // the up arrow to get past. Compared AFTER redaction, so two runs that differ only in a
    // secret still collapse to one entry.
    final history = state.history.isNotEmpty && state.history.last == typed
        ? state.history
        : <String>[...state.history, typed];

    final refusal = ConsoleGuard.refusal(argv);
    if (refusal != null) {
      // Recorded as an entry rather than flashed as a banner: the transcript is the record of
      // what this session did, and "I declined to run this, and why" belongs in it.
      _append(
        ConsoleEntry(argv: argv, notRun: refusal, refused: true),
        history: history,
      );
      return false;
    }

    // Taken BEFORE the await and asked AFTER it — that ordering is the whole mechanism.
    final token = _runs.begin();
    final cancel = CancelToken();
    _active = cancel;
    state = state.copyWith(isRunning: true, history: history);

    final started = DateTime.now();
    ConsoleEntry entry;
    try {
      final result = await ref
          .read(abctlClientProvider)
          .console(argv, cancel: cancel);
      entry = ConsoleEntry(
        argv: argv,
        stdout: clamp(result.stdoutText),
        stderr: clamp(result.stderr),
        exitCode: result.code,
        duration: DateTime.now().difference(started),
      );
    } on AbctlCancelled {
      entry = ConsoleEntry(
        argv: argv,
        notRun: 'Cancelled.',
        duration: DateTime.now().difference(started),
      );
    } catch (error) {
      // A spawn failure, a missing binary, or abgui's own watchdog. abctl never ran or never
      // finished, so there is no exit code and saying "exit 0" would be a lie.
      entry = ConsoleEntry(
        argv: argv,
        notRun: loadErrorText(error),
        duration: DateTime.now().difference(started),
      );
    }

    if (token.isStale) return false;
    _active = null;
    _append(entry, isRunning: false);
    return true;
  }

  /// Stop the in-flight command. The child is killed and the entry records the cancellation —
  /// which is not a failure, because the user asked for it.
  void cancel() {
    _active?.cancel();
  }

  /// Empty the transcript. abgui's list only: nothing on Apple Business or on disk changes, and
  /// the history stays so the commands can be recalled and run again.
  void clear() {
    state = state.copyWith(entries: const <ConsoleEntry>[]);
  }

  void _append(ConsoleEntry entry, {List<String>? history, bool? isRunning}) {
    final next = <ConsoleEntry>[...state.entries, entry];
    state = state.copyWith(
      entries: next.length <= maxEntries
          ? next
          : next.sublist(next.length - maxEntries),
      history: history,
      isRunning: isRunning ?? state.isRunning,
    );
  }

  /// Keep the HEAD of an oversized stream, not the tail.
  ///
  /// abctl prints its payload from the top: a JSON document's opening object, a table's header,
  /// an error's first line. The tail of a truncated 30 MB device list is the least informative
  /// part of it, whereas the head still says what the command answered.
  static String clamp(String text) {
    if (text.length <= maxStreamBytes) return text;
    final kept = text.substring(0, maxStreamBytes);
    return '$kept\n… truncated: abctl printed ${text.length} characters and the console keeps '
        'the first $maxStreamBytes. Run this in a terminal to get all of it.';
  }
}
