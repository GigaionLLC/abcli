# abgui: SwiftUI → Flutter

**Status:** done. The SwiftUI app was removed at v0.4.28; `abgui-flutter/` is the GUI.

## Why

The GUI was macOS-only for exactly one reason: it was written in SwiftUI. Nothing else about it
is Apple-specific. `abctl` already ships Linux, Windows and macOS binaries, and the GUI is a
**facade over that CLI** — it spawns a process and decodes JSON. It holds no Apple Business API
logic, no Keychain binding, and no AppKit-dependent business rules. The entire native surface is
two behaviours in three files: clipboard copy and reveal-in-file-manager.

So the platform lock was accidental, not essential. Flutter removes it and roughly triples the
addressable platforms for a fleet-admin tool whose users are frequently *not* on a Mac.

## The decision, and its cost

One GUI, not two. The SwiftUI tree was deleted once the Flutter app could do everything it could,
including every write verb. Git history keeps it — `git show v0.4.27:abgui/...` — so nothing is
lost that a `git log` cannot recover.

The order mattered: writes were built and adversarially reviewed **first**, against the Swift tree
as the specification, and only then was the tree removed. Deleting it earlier would have thrown
away `ContractTests.swift` while it was still the only place the argv contract was written down.

**A bug that died with it:** the sidebar blanked for several seconds while a command ran (most
visibly when toggling git-source-of-truth). Three fixes missed it; the cause was in the SwiftUI
layout layer. It was never fixed, because the replacement cannot reproduce the mechanism — the run
strip is pinned chrome and nothing is ever replaced by a spinner.

## What the port is not

It is **not** a redesign wearing a new framework. The redesign proposal (context bar, summary
tiles, run strip, grouped plan rows, sidebar icon rail) lands *as part of* this rewrite, because
retrofitting it onto SwiftUI and then porting it would be the same work twice.

It is also **not** a chance to re-derive the safety model. See below.

## The actual risk

Not tables, not packaging. It is that this app's whole value is concentrated in one destructive
path — `diff` → `validate` → `sync --apply --prune` — and that path is the least mechanical and
least testable part of the port. Everything that makes it safe today is implicit in Swift idiom:

- two independent generation counters, which exist because sharing one produced an
  unrecoverable stuck spinner;
- a decode-before-exit-code rule that applies to exactly two verbs;
- `--prune` forced on inside an argv builder rather than decided in a view;
- a contract test asserting the argv shown in the confirmation dialog is byte-identical to the
  argv actually executed.

A Flutter app that ships a beautiful device browser and gets `--prune` coupling subtly wrong is
strictly worse than no port at all.

**Therefore:** `lib/src/abctl/abctl_args.dart` and its contract test are written *before any UI*,
and `sync --apply` is not armed in the Flutter app until every one of those invariants has a Dart
test. The Swift `ContractTests.swift` (1,591 lines) was the specification; its assertions now live
in `abgui-flutter/test/abctl_args_contract_test.dart` and `test/write_safety_test.dart`, which are
the specification now. Porting it was the cheapest, highest-value work in the whole plan.

## Architecture

```
abgui-flutter/lib/
  main.dart            runApp + window bootstrap only
  app.dart             ProviderScope, theme, root shell
  src/
    abctl/             argv builders, error taxonomy, process runner, locator, client facade
    models/            hand-written fromJson — NO codegen (see below)
    state/             ~9 Riverpod notifiers, never one god-object
    platform/          the 3-branch shell-outs: reveal, chmod/icacls, app paths
    ui/shell|widgets|screens|dialogs
```

Three decisions that are not stylistic:

**No `json_serializable`.** The Swift decoders are deliberately *lenient* — a missing or null
field must never blank a screen. Generated decoders throw exactly where these tolerate, so
codegen would convert a cosmetic gap into a crash. Hand-written `fromJson` also keeps CI free of
a `build_runner` step.

**Nine notifiers, never one.** Porting `AppModel` as a single store reintroduces the exact
over-render that blanked the window mid-sync. `LoadToken` is a real type with its own test, not
an `int` maintained by discipline.

**The progress log lives outside Riverpod.** A `ValueNotifier<List<String>>` fed by a 100 ms
coalescing timer, with only the transcript listening. Per-line provider invalidation during a
twenty-minute sync is the same bug in a new language.

## What gets worse

Stated plainly, so nobody discovers these later and thinks they were missed:

- **Tables.** SwiftUI `Table` is `NSTableView`: free column resizing, native selection, correct
  focus ring, elastic scroll, table accessibility semantics, thousands of rows for free. Flutter
  has no equivalent. Sort chevrons, stable tie-broken sort, filtering, multi-select and keyboard
  navigation all become hand-written code shared across ~10 list screens, and dense scrolling
  will be visibly less smooth than today.
- **macOS accessibility.** VoiceOver support in Flutter macOS is a documented weak spot. Screens
  where a glyph is the only error signal need explicit `Semantics()` and will still be announced
  less reliably than the current `.accessibilityLabel` work.
- **Native macOS feel.** Flutter paints every pixel: no vibrancy, no system accent, no native
  focus rings or scrollbar behaviour, no Services menu, no native sheet animation. For a tool
  aimed at Apple-fleet admins this is a real product regression, accepted knowingly.
- **SF Symbols.** ~80–120 icons need mapping to another set; several load-bearing ones have no
  exact twin, so some status language shifts visually.
- **Large selectable text.** The transcript renders as one selectable block so cross-line
  selection works. Flutter's selection over megabyte-scale text is a performance cliff SwiftUI
  did not have.
- **Credential file permissions on Windows.** The 0600-inside-0700 guarantee has no portable Dart
  equivalent. POSIX shells out to `chmod`; Windows uses `icacls /inheritance:r`, which is a
  weaker and less inspectable promise.
- **Download size.** A Flutter bundle plus an embedded abctl is substantially larger than the
  hand-assembled Swift app.

## Packaging

The three things that would otherwise be found at release time:

1. **App Sandbox must stay off.** `flutter create` writes `app-sandbox=true`; with it on,
   `Process.start` of the embedded abctl fails and the stored workspace path stops resolving.
   Both entitlements files are de-sandboxed with the reasoning written into them. This
   permanently rules out Mac App Store distribution — a recorded decision, not a discovery.
2. **abctl is built inside the macOS job, never downloaded.** The bundled binary must be the
   `lipo`'d universal build *and* carry the same Developer ID signature and hardened runtime as
   the app. A binary from the GoReleaser job is thin-arch and unsigned, and fails both checks.
   Signing is inside-out and explicitly not `--deep`.
3. **The Linux glibc floor is the builder's.** Built on a modern runner, the artifact will not
   start on Debian 12 or Ubuntu 22.04. CI pins `ubuntu-22.04`; keep it pinned. This is what
   makes the AppImage's "runs on any distro" claim true — an AppImage bundles the GTK stack it
   needs but *not* glibc, so the pin is load-bearing, not hygiene.

### Windows ships three artifacts, from one payload

A portable zip, an Inno Setup installer (`abgui-setup-x64.exe`), and a Microsoft Store MSIX. The
installer and the MSIX **repackage** what `build-gui-flutter.sh windows` already built rather than
rebuilding — the same "operate on existing output" split as `macos-notarize`, and for a stricter
reason: the release job signs `abgui.exe` and the embedded `abctl.exe` **in place** between the
steps, so a rebuild would ship wrappers around unsigned binaries.

Two things about the Store package are permanent constraints on the app, not packaging trivia:

- **A packaged app must not download executable code at runtime.** abgui complies only because
  abctl is *bundled*. Any future "update abctl in place" feature has to be dead when
  Store-packaged, and it is the *download* that must be gated, not the button. Detection is a
  `GetCurrentPackageFullName` FFI call — no Dart API answers it.
- **`runFullTrust` cannot be removed.** Every Flutter Win32 app has a
  `Windows.FullTrustApplication` entry point, so `msix` always emits it. It is what lets abgui
  spawn abctl at all, and it makes a restricted-capability justification mandatory on every
  submission.

Both, plus the repo variables and secrets a human must create, are in
[windows-store-and-signing.md](windows-store-and-signing.md).

### Linux ships an AppImage, not a .deb

One self-contained executable: no root, no package manager, every distro. A `.deb` was
considered and rejected — it obliges us to declare a runtime dependency list that is correct on
Debian and wrong somewhere else forever, and it serves only the Debian/Ubuntu family. A plain
tarball ships alongside for anyone scripting an install. `appimagetool` is fetched and cached in
`bin/`, and runs with `--appimage-extract-and-run` because CI runners have no FUSE — without
that flag the tool cannot mount even itself.

## Build and CI

| | abgui |
|---|---|
| Build script | `scripts/build-gui-flutter.sh` |
| Make targets | `make gui-check`, `gui-test`, `gui-macos`, `gui-windows`, `gui-linux` |
| CI | `.github/workflows/gui-flutter.yml` (analyze/test everywhere + a real build per OS) |
| Release assets | **The filename discloses the trust state, and nothing is renamed after upload.** A plain name means signed (and on macOS, notarized + stapled); `-unnotarized` means Developer ID signed but not notarized; `-unsigned` means no signature at all; `-store.msix` is the Partner Center package, which cannot be sideloaded. So: `abgui-*-macos[-unnotarized].{dmg,zip}`, `abgui-*-windows-x64[-unsigned].zip`, `abgui-setup-x64[-unsigned].exe`, `abgui-*-windows-x64-store.msix`, `abgui-*-x86_64[-unsigned].AppImage`. No Linux tarball — the AppImage supersedes it. |
| Bundle id | `com.gigaionllc.abgui` |
| Signing / Store | macOS: [release-signing.md](release-signing.md) · Windows: [windows-store-and-signing.md](windows-store-and-signing.md) |

The Flutter macOS app keeps `com.gigaionllc.abgui`, so it installs *over* the previous app rather
than beside it — which is what you want once there is only one.

Local dev without a Flutter SDK: `./tool/flutter.sh analyze` (or `.ps1`) runs in the container
defined by `docker-compose.yml`. The container can analyze, test, and build Linux. It cannot
build Windows (needs MSVC) or anything macOS (needs Xcode on a real Mac).

## Cutover — done at v0.4.28

The release jobs are no longer gated: `abgui-*` assets are the Flutter build on all three
platforms. In one commit the SwiftUI tree, its build script, its CI workflow, its two release jobs,
its Makefile targets, its `.gitignore` lines and the deprecation block in the release notes were
all removed.

What deliberately did **not** happen: `abgui-flutter/` was not renamed to `abgui/`. The Dart
package is already named `abgui` (imports are `package:abgui/...`), so the directory name costs
nothing to leave, and renaming it would churn every CI path filter for cosmetics.

## Open questions

- **VPP / Apps & Books.** The Swift app has a `VPPView` that is deliberately unreachable from the
  sidebar, per the product boundary in `AGENT.md`. Port it in the same quarantined state, or
  leave it out of the Flutter app entirely? Leaving it out is cleaner and reversible.
- **Table widget.** The free path (`two_dimensional_scrollables` + hand-written sort/select) vs a
  commercial grid is a multi-week fork, and a commercial licence is a Gigaion, LLC decision. It
  should be made before the table is designed, not after ten screens depend on one.
- **Riverpod 2 vs 3.** Pinned at 2.6.1 today. Worth confirming before thousands of lines depend
  on it.
