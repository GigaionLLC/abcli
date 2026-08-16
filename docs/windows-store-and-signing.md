<!-- Copyright 2026 Gigaion, LLC -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# Windows packaging, code signing and the Microsoft Store

How `abgui` reaches a Windows machine, what is already built on every tag, and what a human has
to create before the two dark lanes (Authenticode signing, Store submission) light up.

Companion to [release-signing.md](release-signing.md), which covers the macOS half.

**Status: nothing here is active yet.** Both the signing steps and the Store identity injection
are pre-wired in `.github/workflows/release.yml` and gated on credentials that do not exist for
this repo. Every tag today produces the three artifacts below with **no** Authenticode signature
and a **placeholder** Store identity. Turning either on is a settings change, not a code change.

---

## 1. What a tag produces

`gui-flutter-windows` in `.github/workflows/release.yml` runs
[`scripts/build-gui-flutter.sh`](../scripts/build-gui-flutter.sh) three times: `windows`, then
`windows-installer`, then `windows-msix`. The last two **repackage** what the first built — they
never rebuild — because the signing step runs between them and all three artifacts have to wrap
one payload.

| Artifact | Built by | Who it is for |
|---|---|---|
| `abgui-<version>-windows-x64[-unsigned].zip` | `windows` / `windows-zip` | Portable. Unzip and run; nothing is installed or registered. |
| `abgui-setup-x64[-unsigned].exe` | `windows-installer` | The normal download. Per-user by default (no UAC), Start-menu entry, optional desktop icon, real uninstaller. |
| `abgui-<version>-windows-x64-store.msix` | `windows-msix` | Microsoft Store submission only. Unsigned by design — the Store signs it on ingestion — and Windows refuses to sideload it, so it is named `-store` rather than `-unsigned`: no user can be misled into running it. |

All three contain the **embedded `abctl.exe`**. That is not a convenience: `AbctlLocator`
resolves the CLI by absolute path next to `abgui.exe` and never through `PATH`, and every
packaging path asserts the binary is there rather than trusting the previous step —
`build-gui-flutter.sh`'s `require_windows_payload`, and `#error` guards inside `abgui.iss` that
make it a **compile** failure. The failure being defended against is quiet: an app that installs,
launches, and then cannot run a single command.

All three also carry the **MSVC runtime app-local** (`msvcp140.dll`, `vcruntime140.dll`,
`vcruntime140_1.dll` and friends), copied beside `abgui.exe` by
`abgui-flutter/windows/CMakeLists.txt`. Flutter links the runtime dynamically and it is not part
of Windows, so without this the app needs the Visual C++ Redistributable installed separately —
which every dev box has, which is exactly why this class of bug ships. CI hard-fails a Release
directory without those DLLs, because CMake only *warns* when it cannot find them. For the Store
this is also policy **10.2.4.1** (undisclosed dependency on non-integrated software).

### Building them locally

```sh
./scripts/build-gui-flutter.sh windows            # Flutter build + embed abctl + zip
./scripts/build-gui-flutter.sh windows-installer  # -> bin/abgui-setup-x64-unsigned.exe
./scripts/build-gui-flutter.sh windows-msix       # -> bin/abgui-<version>-windows-x64-store.msix
```

Windows only — Flutter cross-compiles nothing for desktop. The installer additionally needs
**Inno Setup 6** (`winget install JRSoftware.InnoSetup`, or `choco install innosetup -y`); the
script probes both the per-user winget location and Program Files (x86) and refuses with a
message naming the fix rather than a bare "command not found".

A `windows-msix` package built locally is a `--store` package: **installable nowhere**, because
`--store` packages are unsigned and Windows will not install an unsigned MSIX. For one you can
actually install and click through, run `dart run msix:create` in `abgui-flutter/` instead —
pubspec's `store: false` makes it test-sign the package (you still have to trust the generated
test certificate on the machine you install it on).

### Installer behaviour worth knowing

* **Per-user by default** — `%LOCALAPPDATA%\Programs\abgui`, no UAC prompt. Passing `/ALLUSERS`
  installs per-machine into Program Files (with UAC), which is what Store validation needs so it
  can find a machine-wide Add/Remove Programs entry; a per-user install writes that entry to
  HKCU where validation cannot see it.
* **Silent install** — `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, optionally `/ALLUSERS`.
  Inno exit codes: `0` success, `2` and `5` cancelled, `4` disk full, `8` reboot required.
* **Uninstall terminates processes running from the install directory first**, scoped by path
  and excluding `unins*`. Both halves matter — see the comments in `abgui.iss`; the short version
  is that a running `abgui.exe` locks its own file and leaves undeletable leftovers, and an
  unfiltered kill takes out the uninstaller's own first phase and turns a successful uninstall
  into exit code `-1`.
* **User data is never removed.** `%LOCALAPPDATA%\abgui\keys` holds the Apple Business API
  private key, which Apple lets you download **exactly once**, and `%LOCALAPPDATA%\abgui\logs`
  holds the run-log audit trail. Neither is inside the install directory, so neither affects
  clean removal. This is a deliberate divergence from the sibling Airclone installer, which does
  offer to delete its own data on uninstall.
* **`AppId` is a fixed GUID and must never change** — upgrade detection and the uninstall
  registry key both hang off it. A new GUID turns the next release into a second installed copy
  instead of an upgrade.

---

## 2. Code signing — Azure Trusted Signing

Signs `abgui.exe`, the embedded `abctl.exe`, and `abgui-setup-x64.exe`, so Windows names a real
publisher instead of "Unknown publisher". It is a cloud HSM service — no USB token, no physical
signing machine, and it works on GitHub-hosted runners. The `--store` MSIX is deliberately **not**
signed here; the Store signs that itself.

### The gate

The steps are `if: ${{ env.HAS_WINDOWS_SIGNING == 'true' }}`, and `HAS_WINDOWS_SIGNING` is
computed at the top of the job from credential **presence** — the same shape as the Apple
certificate gate in the macOS job. Create the secrets and variables and the next tag signs
itself; no workflow edit, no flag to remember to flip.

### What a human must create

Gigaion already runs **one** Azure Artifact/Trusted Signing account and **one** Entra app
registration for the whole org, with these set at the **organization** level and
visibility = *Selected repositories*. Wiring `abcli` up is therefore **adding this repo to the
existing entries**, not provisioning a second signing identity — which is why the names below are
shared across products rather than prefixed per-repo.

Secrets (Org → Settings → Secrets and variables → Actions):

| Secret | What it is |
|---|---|
| `AZURE_TENANT_ID` | Entra tenant id of the signing app registration. |
| `AZURE_CLIENT_ID` | The app registration's application (client) id. |
| `AZURE_CLIENT_SECRET` | Its client secret. Expires — note the rotation date somewhere real. |

Variables:

| Variable | What it is |
|---|---|
| `AZURE_SIGNING_ENDPOINT` | Regional endpoint of the signing account, e.g. `https://wus.codesigning.azure.net/`. |
| `AZURE_SIGNING_ACCOUNT` | The Trusted Signing account name. |
| `AZURE_SIGNING_PROFILE` | The **certificate profile** name. Also part of the gate: it is the one value with no sensible default. |

```powershell
# Adding abcli to the existing org-level entries. `gh` needs the admin:org scope:
#   gh auth refresh -h github.com -s admin:org
$ORG = "GigaionLLC"
gh secret   set AZURE_TENANT_ID       --org $ORG --visibility selected --repos Airclone,abcli --body $TENANT
gh secret   set AZURE_CLIENT_ID       --org $ORG --visibility selected --repos Airclone,abcli --body $APPID
gh secret   set AZURE_CLIENT_SECRET   --org $ORG --visibility selected --repos Airclone,abcli --body $SECRET
gh variable set AZURE_SIGNING_ENDPOINT --org $ORG --visibility selected --repos Airclone,abcli --body $ENDPOINT
gh variable set AZURE_SIGNING_ACCOUNT  --org $ORG --visibility selected --repos Airclone,abcli --body $ACCOUNT
gh variable set AZURE_SIGNING_PROFILE  --org $ORG --visibility selected --repos Airclone,abcli --body $PROFILE
```

A secret is write-only once set: you cannot read one back to copy it to another repo, which is
why the command above re-sets the value across the whole selected list rather than "adding" abcli.

If the account does not exist yet, the order is fixed and the middle step is slow:

1. Create a **Trusted Signing account** in the Azure portal; note its region and endpoint URL.
2. **Identity validation first** — account → Identity validation → New identity → Organization →
   Public → legal name, address, D-U-N-S, formation documents. This needs Microsoft approval
   (days) and is **required** before a Public Trust certificate profile can be created; the
   profile's create form only lists validations in the *Completed* state. Submitting it needs the
   **Artifact Signing Identity Verifier** role on your own user account, which is separate from
   the app's signer role. The service is only offered to organizations in the US, Canada, EU
   and UK.
3. Create the **certificate profile** (type *Public Trust*) once validation is Completed.
   A *Public Trust Test* profile needs no validation and is a good way to smoke-test the CI
   plumbing early — but its signatures chain to a test root and are not publicly trusted, so it
   proves the pipeline, never the build.
4. Create the **Entra app registration** with a client secret and grant it the
   **Artifact Signing Certificate Profile Signer** role at the signing-account scope.

An **OV** profile still draws a SmartScreen "unknown publisher" prompt until the download earns
reputation (days to weeks). An **EV** profile is trusted immediately.

### Verifying, once it is on

Do not trust the green check — download the assets and check the artifacts:

```powershell
Get-AuthenticodeSignature .\abgui-setup-x64.exe | Format-List Status, SignerCertificate
# Expect: Valid, and CN="Gigaion, LLC", RFC-3161 timestamped.
```

Then unzip the portable zip and repeat for `abgui.exe` and `abctl.exe`.

> **All three artifacts are packed after signing — this was not always true.** `windows` used to
> build the portable zip in the same step as the Flutter build, so the zip was packed *before*
> signing and would have shipped unsigned binaries inside a release that had a certificate. That is
> the worst shape for the bug: the release looks signed, and the one file most likely to be scanned
> by an endpoint tool isn't. The installer and the MSIX were never affected — both are produced
> after signing.
>
> Fixed by splitting the zip into `windows-zip`, a "package what already exists" subcommand, which
> the release runs after the signing step. The order in `gui-flutter-windows` is therefore
> load-bearing: **build → verify runtime → sign the exes in place → `windows-zip` → installer →
> sign installer → MSIX.** Do not reorder it, and do not make any of the packaging subcommands
> rebuild — they exist precisely so all three artifacts carry the same signed bytes.

---

## 3. Microsoft Store

### The one rule that shapes the app

**A packaged app must not download executable code at runtime** (Store policy 10.2.x). `abgui`
complies because `abctl.exe` is *bundled* — the release job builds it and copies it next to
`abgui.exe` before the package is made, and nothing is fetched on first run.

If an "update abctl in place" feature is ever added, it **must be hard-disabled when the app is
Store-packaged**, and disabling the button is not enough: the download itself is the violation,
so the check has to gate the fetch. Detect packaging by calling the Win32
`GetCurrentPackageFullName` (kernel32) over `dart:ffi` — it returns `APPMODEL_ERROR_NO_PACKAGE`
(15700) for the zip and installer builds, and `ERROR_SUCCESS` plus a package full name inside the
MSIX. There is no Dart or Flutter API that answers this; `Platform` and `package_info_plus`
cannot tell the two builds apart. Treat any failure to get an answer as "packaged" — failing
closed costs a feature, failing open costs the listing.

(The write would fail anyway — an installed MSIX lives under `%ProgramFiles%\WindowsApps`, whose
ACLs deny the running user write access — but "the OS stopped us" is not a compliance argument,
and by then the download has already happened.)

### Identity is validated on upload, before certification starts

Four manifest fields are checked, and **the first failure masks the rest**, so fix them as a set
rather than one round trip each:

| Manifest field | Source |
|---|---|
| `Package/Identity/Name` | the reserved package name |
| `Package/Identity/Publisher` | the Partner-Center-assigned publisher id, `CN=<GUID>` |
| `Package/Properties/DisplayName` | must be a **reserved app name** |
| `Package/Properties/PublisherDisplayName` | the Store account's publisher display name |

None of this comes from a signing certificate. `--store` packages are unsigned.

Because this repo is **public** and the publisher id is a GUID tied to the account, the real
identity lives in repo variables and `abgui-flutter/pubspec.yaml` keeps obvious placeholders:

| Variable | Maps to | Notes |
|---|---|---|
| `MSIX_IDENTITY_NAME` | `Package/Identity/Name` | Copy verbatim from Partner Center. |
| `MSIX_PUBLISHER` | `Package/Identity/Publisher` | `CN=<GUID>`. **Never commit this.** |
| `MSIX_DISPLAY_NAME` | `Package/Properties/DisplayName` | Must be a reserved app name — **and** is what users read on the Start-menu tile, because `msix` drives both from one value. Reserving a short name is the only way to get a short tile. |

```powershell
gh variable set MSIX_IDENTITY_NAME --repo GigaionLLC/abcli --body "<Package/Identity/Name>"
gh variable set MSIX_PUBLISHER     --repo GigaionLLC/abcli --body "CN=<GUID>"
gh variable set MSIX_DISPLAY_NAME  --repo GigaionLLC/abcli --body "<a RESERVED app name>"
```

If any of the three is unset the build still runs, emits a `::warning::`, and produces a package
Partner Center **will** reject. That warning exists because the sibling project shipped a
placeholder-identity package silently and it took four rejected uploads to unpick.

`publisher_display_name` stays in pubspec as `Gigaion, LLC`: it is the company name, already
public throughout this repo, and it is not a GUID. It must match the Store account's publisher
display name byte-for-byte — `GigaionLLC` is a different string and is rejected.

The **package family name** is not a field you set; it is derived as
`<Identity/Name>_<base32(SHA-256(Publisher as UTF-16LE)[0..7])>` over the alphabet
`0123456789abcdefghjkmnpqrstvwxyz`. Computing it locally is a quick way to prove a publisher
string is byte-exact before uploading a large package.

Because `--store` packages are unsigned, a wrong identity can be corrected **without rebuilding**:
`makeappx unpack` → edit `AppxManifest.xml` → delete `AppxBlockMap.xml` → `makeappx pack`
(which regenerates the block map).

### Reserving the name

1. Register (or use the existing) **company** developer account at
   <https://storedeveloper.microsoft.com>. Publisher display name must be **Gigaion, LLC**.
   Business verification is a review, measured in business days.
2. Reserve the app name. `abgui` alone is unlikely to be available or meaningful in a consumer
   catalogue; a descriptive title is what actually gets reserved, and a **short** name has to be
   reserved separately under Product management → *Manage app names* if you want a short tile.
3. Open the product → **Product management → Product identity** and copy the package identity
   name, the publisher `CN=<GUID>`, the publisher display name, and the Store ID.
4. Set the three `MSIX_*` variables above. The next tag produces a submittable package.

### Submission steps

1. Cut the tag. Confirm CI produced `bin/abgui-<version>-windows-x64-store.msix` and that the job did
   **not** print the placeholder-identity warning.
2. Download the `.msix` from the release page. Verify the payload before uploading anything —
   `makeappx unpack` it and confirm `abctl.exe` is inside. The build refuses to package without
   it, so this is a re-check, not the gate.
3. Partner Center → the reserved product → **Packages** → upload the `.msix`. Identity is
   validated here, immediately.
4. **Submission Options → Restricted capabilities.** Required on every packaged submission,
   because `msix` emits `<rescap:Capability Name="runFullTrust"/>` for any Flutter/Win32 app —
   the entry point is `Windows.FullTrustApplication`. It cannot be removed and the app cannot run
   without it. Paste something like:

   ```
   abgui is a Win32 desktop application (Flutter + C++) packaged for the Store with the
   Desktop Bridge. Its application entry point is Windows.FullTrustApplication, which
   requires runFullTrust.

   1. THE BUNDLED abctl COMMAND-LINE TOOL RUNS AS A CHILD PROCESS
   abgui is a graphical front end for abctl, the open-source Apple Business Manager
   command-line tool published by the same author. The package ships its own copy of
   abctl.exe and starts it as a local child process, reading its JSON output over the
   process's standard streams. Creating a child process requires full trust. No executable
   code is downloaded at runtime - abctl.exe is bundled in the package and is built from
   the same source revision as the app.

   2. GIT-BACKED WORKSPACE ON DISK
   The product manages Apple Business Manager configuration as files in a folder the user
   chooses (a "GitOps workspace"), reading and writing that folder directly and running the
   user's own git. The brokered file-picker model cannot express "keep this directory tree
   in sync".

   abgui has no accounts of ours, no telemetry and no servers of ours. It talks only to
   Apple's Business Manager API, using an API key the user creates in their own tenant and
   stores on their own machine.
   ```

   In **Notes for certification**, state plainly that the package contains everything it needs —
   `abctl.exe` and the Microsoft Visual C++ runtime files (`msvcp140.dll`, `vcruntime140.dll`,
   `vcruntime140_1.dll`) — and that nothing is downloaded on first run. Then **walk your own
   tester notes in the shipping build before submitting**: every step in that field is a promise
   about behaviour, and one stale instruction fails the whole submission on its own.

5. **Store listing** — description, screenshots, category, support contact, and a
   **privacy-policy URL** (required). Point it at the repo's privacy statement.
6. **Age ratings**, pricing and markets, then submit. Certification takes days.
7. Include the **Product ID** in any correspondence with Microsoft, and expand every collapsed
   row of a certification report before starting work on it — the summary line carries no
   actionable detail, and *Supporting files → Download ZIP* has the reviewer's logs and
   screenshots.

### Not wired up: automated submission

There is no `msstore publish` step in this repo's workflow. The Store CLI lane exists in the
sibling project and is deliberately not copied: the first submission has to be manual anyway
(the listing must be complete before anything can be published), it needs a second set of
credentials — `STORE_TENANT_ID` / `STORE_CLIENT_ID` / `STORE_CLIENT_SECRET` / `STORE_SELLER_ID`
plus a `STORE_APP_ID` — and none of that is worth carrying while the reservation does not exist.
Add it if and when tag-triggered Store updates are actually wanted.

---

## 4. Checklist before the first Store submission

- [ ] Company developer account verified, publisher display name is exactly `Gigaion, LLC`.
- [ ] App name reserved; a short name reserved too if the tile matters.
- [ ] `MSIX_IDENTITY_NAME`, `MSIX_PUBLISHER`, `MSIX_DISPLAY_NAME` set as repo variables.
- [ ] A tag built cleanly with **no** placeholder-identity `::warning::` in the job log.
- [ ] `abctl.exe` verified inside the unpacked `.msix`.
- [ ] Restricted-capability justification for `runFullTrust` written.
- [ ] Privacy-policy URL live.
- [ ] Install → use → uninstall walked by hand on a machine that is not a dev box, and the
      uninstaller's exit code asserted to be `0` — not merely that the directory is gone.
