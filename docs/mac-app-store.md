# Mac App Store — why abgui cannot ship there today

**Status: BLOCKED, and not on packaging.** This is an architecture decision, not a CI task. Do not
attempt a MAS target until the work below is done; you would spend the effort and still be blocked.

Companion to [windows-store-and-signing.md](windows-store-and-signing.md) (Microsoft Store — which
*is* reachable) and [abgui-flutter-port.md](abgui-flutter-port.md).

## What ships today

macOS distribution is **Developer ID + notarization**, not a store: a signed, notarized, stapled
`.dmg`/`.zip` on GitHub Releases. It passes Gatekeeper with no store review and no sandbox. That is
a complete, supported distribution channel — the Mac App Store would be an *addition*, not a fix.

| | Today (Developer ID) | Mac App Store |
|---|---|---|
| Sandbox | **off** | **mandatory** |
| Review | none | Apple review, per release |
| Signing | Developer ID Application | 3rd Party Mac Developer Application |
| Distribution | GitHub Releases | App Store only |
| abctl | spawned subprocess | **cannot work — see below** |

## The blocker

The Mac App Store requires App Sandbox. Under the sandbox:

1. **A child process inherits the sandbox but NOT the parent's security-scoped grants.** This is the
   fatal one. abgui's whole job is running abctl against a GitOps workspace the user picked. Under
   MAS that folder is reached through a security-scoped bookmark held by *the app*. The spawned
   abctl would be handed a path it has no permission to open — and it would fail at the filesystem,
   not at a permission dialog, so the failure would be obscure.
2. **`~/.abctl/contexts.yaml` is outside the container.** Credentials and context selection are
   shared with the CLI on purpose — that is a feature, and the sandbox forbids it.
3. **A sandboxed app may only exec code bundled and signed at build time.** abctl *is* bundled, so
   this one is survivable; it only rules out ever fetching a newer CLI at runtime.

(1) and (2) are not workaroundable while abctl is a subprocess. Entitlements do not exist for either.

This is the same wall Airclone hit, and its analysis is worth reading directly:
`D:\git\Airclone\dev\apple-appstore-and-macos.md`.

## The unblock: abctl as a library, not a process

Make abctl an **in-process library** called over `dart:ffi`, so the file I/O happens inside the app
and therefore *inside the app's own grants*:

```
go build -buildmode=c-shared -o libabctl.dylib ./cmd/libabctl
```

Go supports this natively, and Dart FFI can call it. In-process I/O holds the host's security-scoped
grants, which dissolves blocker (1). Credentials would move into the app container, which addresses
(2) at the cost of no longer sharing state with the CLI on that build.

**abgui already has the seam this plugs into.** `lib/src/abctl/process_runner.dart` defines an
abstract `AbctlRunner` with `ProcessRunner` as one implementation, and `RecordingRunner` already
decorates it. A `LibAbctlRunner` is a third implementation: **no screen, no store, and no dialog
changes.** That is the single most encouraging fact about this whole idea, and it is not an accident
— the seam exists because the Swift app needed it for testing.

Airclone is building exactly this shape (`LibRcloneClient` beside `HttpRcloneClient`), so the two
projects would share the pattern and the CI machinery.

### What it actually costs

- A `cmd/libabctl` C-ABI surface over the existing `internal/` packages: a handful of exported
  functions taking/returning JSON strings, so the wire contract stays the one already tested.
- Per-platform cgo builds (macOS universal, Windows, Linux) — new CI work.
- Dart FFI bindings plus lifetime/threading discipline: a Go runtime in-process is not free, and
  blocking calls must not sit on the UI isolate.
- Sandbox plumbing: security-scoped bookmarks for the workspace, credential storage relocated into
  the container, entitlements, provisioning profile.
- App Store review, screenshots, privacy disclosures, and a per-release submission lane.

### What gets worse if we do it

- **The workspace stops being an ordinary folder.** Bookmarks are stored state that can go stale;
  "choose your gitops repo" becomes a thing that can silently lose access.
- **Credentials fork.** The MAS build cannot share `~/.abctl/contexts.yaml`, so a user running both
  the CLI and the Store app configures twice. For a tool whose selling point is *the GUI and the CLI
  are the same engine*, that is a real product regression.
- **Release cadence gains a human gate.** Apple review sits between a tag and users.
- Two runner implementations to keep behaviourally identical, or one that is only exercised on one
  platform — which is how divergence starts.

## Recommendation

**Do the Microsoft Store first** (see [windows-store-and-signing.md](windows-store-and-signing.md)).
It is packaging work, not architecture: MSIX runs a packaged full-trust Win32 app, so spawning the
bundled `abctl.exe` and reading `%USERPROFILE%\.abctl\` both keep working. Same app, new channel.

**Treat MAS as a separate project with its own decision**, and take it only if reaching users who
will *only* install from the App Store is worth forking the credential story. For an
Apple-fleet-admin tool whose users already run a CLI, that is genuinely not obvious — a notarized
DMG is not a lesser product, it is the normal way developer tools ship on macOS.

If `libabctl` gets built for other reasons — startup latency, or removing the process boundary from
the write path — then MAS becomes cheap, and the order reverses. Worth revisiting then, not before.

## Prerequisites checklist, for when it becomes real

- [ ] `cmd/libabctl` c-shared build + a JSON C-ABI over the existing verbs
- [ ] `LibAbctlRunner` (dart:ffi) implementing `AbctlRunner`, passing the same contract tests as
      `ProcessRunner` — the argv contract suite is the specification and must pass unmodified
- [ ] Security-scoped bookmarks for the workspace, with an explicit "access lost" recovery path
- [ ] Credentials relocated into the app container, and the divergence from the CLI documented
      **in the app**, not just here
- [ ] `3rd Party Mac Developer Application` cert, provisioning profile, sandbox entitlements
- [ ] App Store Connect API key + a submission lane in CI
- [ ] A decision recorded on whether the Developer ID build keeps shipping in parallel (it should)
