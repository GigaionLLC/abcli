# macOS release signing

`abgui` can be shipped as a Developer ID-signed and notarized macOS app. Local builds still
work without secrets and fall back to ad-hoc signing.

This covers `abgui.app`, the embedded `abctl` inside that app bundle, and the DMG installer.
The standalone cross-platform `abctl` archives remain signed through the existing
Sigstore/cosign checksum flow.

## GitHub Actions secrets

Add these repository secrets under **Settings -> Secrets and variables -> Actions**:

| Secret | Required | Notes |
|---|---:|---|
| `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64` | yes | Base64 contents of `developerID_application.p12`. |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD` | yes | Password used when exporting the `.p12`. |
| `APPLE_TEAM_ID` | yes | Your Apple Developer Team ID. Also used for notarization. |
| `APPLE_ID` | notarization | Apple ID email for `notarytool`. |
| `APPLE_APP_SPECIFIC_PASSWORD` | notarization | App-specific password for the Apple ID. |
| `APPLE_CODESIGN_IDENTITY` | optional | Defaults to `Developer ID Application`. Set the full identity if needed, for example `Developer ID Application: Gigaion, LLC (TEAMID)`. |
| `APPLE_KEYCHAIN_PASSWORD` | optional | Temporary CI keychain password. Defaults to the GitHub run ID. |

Create the base64 value from the `.p12`:

```sh
base64 -i developerID_application.p12 | pbcopy
```

On Windows PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("developerID_application.p12")) | Set-Clipboard
```

## What the release workflow does

On `v*` tags, `.github/workflows/release.yml`:

1. Imports the `.p12` into a temporary macOS keychain.
2. Builds `abgui.app` with the universal embedded `abctl`.
3. Signs nested executables first, then the `.app`, using hardened runtime and timestamping.
4. Builds and immediately uploads signed zip + DMG release assets.
5. Runs a separate best-effort notarization job when `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and
   `APPLE_TEAM_ID` are present.
6. Rebuilds, notarizes, staples, and replaces the release assets with `gh release upload --clobber`.

The split keeps the release page from waiting on Apple's notary queue. A Developer ID signature without
notarization is useful for provenance, but modern macOS Gatekeeper still expects notarization for
internet-distributed apps; once notarization finishes, the signed assets are replaced in place.

## App IDs and provisioning profiles

No App ID or provisioning profile is needed for the current `abgui` release path. `abgui` does not use Apple
app services such as iCloud, Push Notifications, Sign in with Apple, App Groups, associated domains, or
keychain access groups. If a future version adds one of those capabilities, register an App ID and add the
matching entitlements then.
