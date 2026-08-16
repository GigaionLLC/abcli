# Upcoming release

Theme: **the GUI stops being macOS-only**.

`abctl` has shipped Linux, Windows and macOS binaries for a long time; the GUI was macOS-only for
exactly one reason — it was written in SwiftUI. This release moves the GUI to Flutter and ships it
for all three desktop platforms. Nothing about the CLI, the reconcile engine, or the Apple Business
API surface changes.

See **[abgui-flutter-port.md](abgui-flutter-port.md)** for the full rationale, the risks, and what
regresses.

## User-facing additions

- **abgui runs on Windows and Linux.** One self-contained bundle per platform with `abctl` embedded
  inside it — no separate install, no `PATH` lookup. Linux ships a single-file **AppImage** (plus a
  tarball) so it runs on any distro without root or a package manager.
- **Windows ships a real installer**, `abgui-setup-x64.exe` (Inno Setup): per-user by default with
  no UAC prompt, Start-menu entry, optional desktop icon, silent install for fleet deployment, and
  an uninstaller that removes everything it put down — while deliberately never touching the
  private key or the run-log audit trail, which live outside the install directory. A **Microsoft
  Store package** (`.msix`) is built on every tag too; it carries placeholder identity until a Store
  reservation exists. See **[windows-store-and-signing.md](windows-store-and-signing.md)**.
- **The Windows build is now self-contained.** The MSVC runtime (`msvcp140.dll`,
  `vcruntime140*.dll`) is copied next to `abgui.exe` and CI hard-fails if it is not. Flutter links
  it dynamically and it is not part of Windows, so every previous Windows artifact silently required
  the Visual C++ Redistributable — invisible on any dev box, a missing-DLL dialog before first paint
  on a clean one.
- **A purpose-built table.** Every list screen shares one widget with sortable, resizable,
  type-aware columns; a severity stripe that encodes state in form rather than colour alone;
  filter chips with real semantics; in-cell match highlighting; multi-select with keyboard
  navigation; a density toggle; and CSV export of exactly what is on screen.
- **The window no longer blanks while a command runs.** Progress lives in a pinned run strip
  showing the exact command line, live output, elapsed time and Cancel. Nothing is replaced by a
  spinner, and each screen owns its own load state, so refreshing one cannot blank another.
- **Per-screen status in the sidebar.** A pip per item shows loading, stale or errored, so a
  failure on one screen is visible from every other screen.
- **Diagnostics built in.** Command log with per-verb timings, on-disk run logs with reveal-in-file-
  manager, an embedded console that injects credentials and context, and a System Health screen
  whose whole block copies in one click for bug reports.

## Safety and scope

- **Writes are gated, and the gating is structural rather than conventional.**
  - `--prune` is not a parameter anywhere in the app. `ApplyOptions` has a private constructor and
    three named public ones (`additive`, `additiveAllowingDeletes`, `gitAuthoritative`); `prune` is
    a read-only field, so a checkbox has nothing to bind to, and the dangerous fourth combination —
    git-as-truth *without* prune, i.e. a half-applied desired state — is unrepresentable. A test
    scans all of `lib/` and fails if the flag, a `prune:` argument, or a `bool …prune` field appears
    outside `abctl_args.dart`.
  - The command shown in the confirmation **is** the command executed: the dialog renders from the
    same function the runner receives, pinned by a test that drives all 11 write verbs through a
    tapped runner and asserts identity of both the token list and the rendered line.
  - A typed confirmation approves a *specific command*, not a phrase. Escalating the plan (or
    toggling removals on) clears the field and re-arms the gate — in both directions.
  - `sync --apply` and `validate` decode stdout **before** mapping the exit code, because abctl
    prints a valid document and exits non-zero; mapping first discards the per-item outcomes of a
    partially applied sync.
  - Success is the receipt, never the exit code. Every row `done` plus a non-zero exit renders
    "Applied N, but the run FAILED". A cancelled or timed-out apply reports an **unknown** state —
    never a clean failure — and says plainly that some writes may have landed.
- Every write surface was reviewed by two adversarial passes whose brief was to break these
  invariants, not confirm them; each finding was fixed with a regression test named after the
  failure it prevents.
- **The SwiftUI app has been removed.** `abgui` is now the Flutter build on every platform, and it
  installs over the previous macOS app (same bundle id, `com.gigaionllc.abgui`). The old source
  remains in git history at tag `v0.4.27`. Its long-standing sidebar-blanking bug is gone with it —
  the replacement's layout cannot reproduce the mechanism.
- The Flutter macOS app is deliberately **unsandboxed**: a sandboxed app cannot spawn the embedded
  `abctl` nor resolve a stored workspace path. This permanently rules out Mac App Store
  distribution — a recorded decision, unchanged in practice from the Swift app.
- On Windows the private-key file is protected by an explicit ACL (`icacls /inheritance:r`) rather
  than POSIX mode `0600`. That is a **weaker** guarantee, and it is documented at the point of use.

## Release gates

- `go test ./...`, `go vet ./...`, `gofmt -l`, and `git diff --check` must pass.
- `dart format --set-exit-if-changed`, `flutter analyze` (zero issues) and `flutter test` must pass.
- The Flutter app must BUILD on all three platforms in CI, and each build must prove the embedded
  `abctl` is present and executes from the location the runtime locator resolves.
- The Linux job stays pinned to `ubuntu-22.04`; the artifact's glibc floor is the builder's.
- The Windows job hard-fails if the MSVC runtime is not next to `abgui.exe`, and the installer and
  MSIX both refuse to package a bundle with no embedded `abctl.exe`.
- Release assets are signed/notarized on macOS; Windows and Linux ship unsigned. The Windows
  Authenticode steps are pre-wired and light up the moment the Azure signing credentials exist.
