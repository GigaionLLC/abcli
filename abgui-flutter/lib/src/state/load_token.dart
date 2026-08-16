// Copyright 2026 Gigaion, LLC
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The two things every store in this layer needs from a load that are not domain state: a way
/// to ask "is the result I am about to publish still the one anybody is waiting for?", and a way
/// to turn whatever was thrown into the single sentence an error slot shows. Both live here so
/// that no store re-invents either — the Swift app had four spellings of the second one and one
/// shared, hand-maintained integer for the first.
library;

import 'package:abgui/src/abctl/abctl_error.dart';

/// Issues [LoadToken]s for ONE concern, and is the only thing in the program that can make them
/// stale.
///
/// **Why staleness is a type and not the `Int` the Swift app used.** `AppModel` ended up with two
/// counters — `loadGeneration` for the resource lists and `workGeneration` for the plan/seed pair
/// — and the comment above the second one is a bug report. They were ONE counter first. `run()`
/// bumped it for every resource list, so navigating to Configurations while a seed was in flight
/// invalidated the SEED's generation; the seed's completion guard then failed, `isSeeding` was
/// never cleared, and the Diff screen sat on "Initializing workspace from the tenant…" with
/// Refresh and Verify disabled until the app was relaunched. Nothing about the code said the two
/// concerns were sharing anything; the sharing WAS the tidiness.
///
/// Here the counter is not a number any caller can read, bump, or pass to the wrong place: it
/// lives inside the issuer, and a token remembers which issuer minted it. Two concerns therefore
/// need two `LoadGeneration`s — a store that wants a pane's loads to be independent gives that
/// pane its own — and a token issued by A can only ever be made stale by A. "Accidentally share
/// the counter" is not a sentence that can be written against this API.
class LoadGeneration {
  LoadGeneration(this.label);

  /// Names the concern this issues for (`gitops.plan`, `inventory.devices`). Diagnostics only —
  /// it is what makes a token's `toString()` legible in a failed expectation, where `#3 stale`
  /// on its own says nothing about WHICH load was superseded.
  final String label;

  int _latest = 0;

  /// Start a load and take the receipt. Every token issued before this one is stale from here on,
  /// which is the whole mechanism: the newest caller always wins, and the loser finds out by
  /// asking rather than by being told.
  LoadToken begin() {
    _latest += 1;
    return LoadToken._(this, _latest);
  }

  /// Orphan everything in flight WITHOUT starting anything new — no token is current afterwards.
  ///
  /// This is the "the user started over" case: choosing a different workspace has to abandon a
  /// diff computed against the previous one, and that abandoned run must not later publish a plan
  /// (or clear a spinner) for a folder nobody is looking at any more.
  void invalidate() {
    _latest += 1;
  }
}

/// The receipt for one load. Holds no result and no state of its own — it answers exactly one
/// question, and it asks its issuer rather than trusting a number the caller kept.
class LoadToken {
  const LoadToken._(this._generation, this._serial);

  final LoadGeneration _generation;
  final int _serial;

  /// True once a newer load (or an [LoadGeneration.invalidate]) has taken over this concern.
  ///
  /// A stale run must publish NOTHING: not its rows, not its error, and above all not "finished
  /// loading" — the run that replaced it is still working, and clearing its spinner is how the
  /// Swift app came to show a stale plan with the Apply button enabled.
  bool get isStale => _generation._latest != _serial;

  bool get isCurrent => !isStale;

  @override
  bool operator ==(Object other) =>
      other is LoadToken &&
      identical(other._generation, _generation) &&
      other._serial == _serial;

  /// Identity of the issuer, not its label: two generations may legitimately share a label (a
  /// store rebuilt in a test), and tokens from them are still not interchangeable.
  @override
  int get hashCode => Object.hash(identityHashCode(_generation), _serial);

  @override
  String toString() =>
      'LoadToken(${_generation.label}#$_serial${isStale ? ', stale' : ''})';
}

/// The one sentence an error slot shows, from whatever was thrown.
///
/// [AbctlError.message] is already written for a human — it names the likely cause and what to do
/// — so it is used verbatim; abctl's own stderr reaches the user through [AbctlCliError] the same
/// way. Anything else that lands here is a bug on abgui's side rather than something the tenant
/// did, and its `toString()` (which for a Dart `Error` carries the type and often a stack hint) is
/// the most useful thing available. `AbctlCancelled` should never reach an error slot at all:
/// every store handles cancellation as a normal outcome before it can become a banner, because a
/// user who pressed Cancel does not need to be told the command failed.
String loadErrorText(Object error) {
  if (error is AbctlError) return error.message;
  return error.toString();
}
