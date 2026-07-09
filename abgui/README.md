# abgui

A native **Swift / SwiftUI** macOS front-end for [`abctl`](../docs/design-abctl.md), the
GitOps + imperative CLI for the **Apple Business API**. abgui is **frontend-only**: it
shells out to an **embedded** `abctl` (`-o json`), decodes the output, and renders it.
Every Apple Business behaviour — auth, the reconcile engine, archive-on-overwrite — stays
in `abctl`.

`abgui` is one of the tools shipped by the [`abcli`](../README.md) repository, alongside
the cross-platform `abctl` CLI.

> ### 🤖 Built by AI
> abgui is designed, written, tested, and documented by an autonomous AI coding agent
> (Anthropic's Claude), directed by Gigaion, LLC — the same openly-disclosed, AI-built,
> human-directed approach used across Gigaion, LLC's open-source projects.

**Design & rationale:** [`../docs/abgui-design.md`](../docs/abgui-design.md).

## Self-contained by design

A release build is **one `.app`** with a universal `abctl` embedded inside it
(`abgui.app/Contents/Resources/abctl`), resolved by its bundled path — no separate CLI
install, no `PATH` dependency, and the CLI is version-locked to the GUI. Your credentials
are **not** bundled: abgui reuses `abctl`'s connection contexts (`~/.abctl/contexts.yaml`)
and never reads key material.

## Build & run (macOS only)

Requires macOS 14+ and a Swift toolchain (Xcode or the Command Line Tools). All logic is
in [`../scripts/build-gui.sh`](../scripts/build-gui.sh); drive it from the repo root:

```sh
make gui-test    # swift test — decode + exit-code logic, offline, no credentials
make gui-app     # assemble the universal abgui.app (embeds a universal abctl)
make gui-run     # build + launch locally
```

During development you can point abgui at a locally-built CLI instead of the bundled one:

```sh
export ABGUI_ABCTL=/path/to/abctl        # dev override; the shipped app always uses the embedded binary
```

## Release signing

Local builds are ad-hoc signed. Tagged GitHub releases can be Developer ID-signed and
notarized when the Apple signing secrets are configured; see
[`../docs/release-signing.md`](../docs/release-signing.md).

If you download a non-notarized development artifact, macOS may quarantine it. Strip it once:

```sh
xattr -dr com.apple.quarantine /Applications/abgui.app
```

Then double-click. See the design doc section 6 for why the app is intentionally **not** sandboxed.

## Sync behavior

The Diff / Drift screen computes the same plan as `abctl diff --json`. By default abgui treats the selected
workspace's `gitops/` tree as the source of truth and the Apply sheet keeps deletes/detaches enabled so the
tenant can converge to the repo.

The Apply sheet exposes an **Advanced sync behavior** section:

- **Refresh: Smart** (default) does a cheap Apple metadata list, reuses cached profile hashes when the
  baseline ID and `updatedDateTime` still match, and fetches profile XML only when needed for comparison,
  pull/prune, or archive-before-overwrite.
- **Refresh: Full Apple refresh** re-downloads profile XML for every live custom configuration.
- **Refresh: Metadata/cache only** is fastest, but should be used only when the local baseline cache is
  complete enough for the operation.
- **Verify: Targeted** (default) refreshes blueprint membership after apply without re-downloading every
  profile XML body.
- **Verify: Full** performs a full post-apply live configuration and blueprint refresh.
- **Verify: None** trusts successful write responses and skips post-apply verification.

Progress and final results are shown in separate panes; once results are posted, the apply spinner stops and
the close button reads **Done**.

## Layout

```
Sources/abgui/Backend/   AbctlRunner (protocol) · ProcessRunner (actor) · AbctlLocator · AbctlClient
Sources/abgui/Models/    JSONValue · Resource · Contract (WhoamiResult, VersionInfo)
Sources/abgui/           App · AppModel (@Observable) · ContentView
Tests/abguiTests/        MockAbctlRunner + decode/exit-code contract tests
Packaging/Info.plist     .app bundle template (@VERSION@ substituted at assembly)
Resources/AppIcon.png    1024² icon master → .icns via sips/iconutil at build (build-gui.sh)
```

## License

[AGPL-3.0-or-later](../LICENSE) — Copyright © 2026 Gigaion, LLC. See [../NOTICE](../NOTICE).
