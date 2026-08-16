#!/usr/bin/env bash
#
# scripts/build-gui-flutter.sh — build abgui (the cross-platform Flutter GUI) and package a
# self-contained bundle with abctl EMBEDDED inside it, for macOS, Windows or Linux.
#
# This replaced the SwiftUI app's build script, removed at v0.4.28.
# See docs/abgui-flutter-port.md.
#
#   ./scripts/build-gui-flutter.sh check     # dart format --set-exit-if-changed + flutter analyze
#   ./scripts/build-gui-flutter.sh test      # flutter test
#   ./scripts/build-gui-flutter.sh macos           # build + embed + sign → .dmg and .zip
#   ./scripts/build-gui-flutter.sh macos-notarize  # notarize + staple what `macos` just built
#   ./scripts/build-gui-flutter.sh windows         # build + embed → .zip
#   ./scripts/build-gui-flutter.sh windows-zip        # repack the .zip from what is on disk
#   ./scripts/build-gui-flutter.sh windows-installer  # Inno Setup → abgui-setup-x64.exe
#   ./scripts/build-gui-flutter.sh windows-msix       # Store package → .msix
#   ./scripts/build-gui-flutter.sh linux           # build + embed → .AppImage
#   ./scripts/build-gui-flutter.sh clean
#
# `macos` notarizes inline when APPLE_NOTARIZE=1; the release splits the two so the signed
# assets can be uploaded before anyone waits on Apple.
#
# `windows-zip`, `windows-installer` and `windows-msix` REPACKAGE what `windows` already built —
# same split, same reason as `macos-notarize`. All three Windows artifacts must contain
# byte-identical payloads, and the release signs the exes IN PLACE between the build and the
# packaging, so none of them may rebuild and all three must be produced AFTER signing.
#
# `check` and `test` run anywhere (including the Linux dev container — see docker-compose.yml).
# Each platform target MUST run on that platform: Flutter cross-compiles nothing for desktop,
# and macOS signing/notarization additionally requires Xcode on a real Mac.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  c_r=$'\033[0m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_e=$'\033[31m'
else
  c_r=""; c_g=""; c_y=""; c_e=""
fi
log()  { printf '%s==>%s %s\n'      "$c_g" "$c_r" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$c_y" "$c_r" "$*" >&2; }
die()  { printf '%serror:%s %s\n'   "$c_e" "$c_r" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# A warning that also survives into GitHub's run summary.
#
# `warn` writes to stderr, which is right for a human but disappears into a collapsed log
# group in Actions — and the packaging warnings this is used for (a Store package built with
# placeholder identity) are precisely the ones nobody reads until Partner Center rejects the
# upload. `::warning::` must go to STDOUT: Actions parses workflow commands from the step's
# stdout, so emitting it on stderr would be a no-op annotation that still looked correct here.
gha_warning() {
  warn "$*"
  [ -n "${GITHUB_ACTIONS:-}" ] && printf '::warning::%s\n' "$*"
  return 0
}

GUIDIR="$repo/abgui-flutter"
APPNAME="abgui"
OUT="$repo/bin"

# The full descriptive version, injected into abctl and used in artifact filenames.
#
# ABGUI_VERSION pins it, and CI MUST set it. `git describe --dirty` is not stable across two
# invocations in the same job: `flutter build` rewrites tracked files (GeneratedPluginRegistrant,
# pubspec.lock), so the tree is clean on the first call and dirty on the second. That bit the
# v0.4.28 release — `macos` produced abgui-v0.4.28-macos.zip, then `macos-notarize` looked for
# abgui-v0.4.28-DIRTY-macos.zip, found nothing, and the notarized assets never shipped.
#
# Keep `--dirty` for local builds: there it is a genuine warning that the artifact does not
# correspond to any commit.
VERSION="${ABGUI_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
LDFLAGS="-s -w -X github.com/GigaionLLC/abcli/internal/cli.version=$VERSION"

# Flutter's --build-name becomes CFBundleShortVersionString on macOS, which Apple requires to
# be at most three dot-separated integers. `git describe` gives things like
# "v0.4.27-3-gabc1234" and "v0.4.27-rc1", none of which Apple accepts — an invalid value is
# rejected at NOTARIZATION, i.e. twenty minutes into a release, so it is normalised here.
# --build-number takes the commit count, which is monotonic and satisfies the "must increase"
# rule for any future Store/updater story without us having to invent one.
BUILD_NAME="$(printf '%s' "$VERSION" | sed -n 's/^v\{0,1\}\([0-9]\{1,\}\(\.[0-9]\{1,\}\)\{0,2\}\).*/\1/p')"
[ -n "$BUILD_NAME" ] || BUILD_NAME="0.0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

CODESIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
NOTARIZE="${APPLE_NOTARIZE:-${NOTARIZE:-0}}"
NOTARY_TIMEOUT="${APPLE_NOTARY_TIMEOUT:-20m}"

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_flutter() {
  have flutter || die "no flutter SDK on PATH — install it, or use ./tool/flutter.sh to run in Docker."
}

require_host() {
  local want="$1" got
  got="$(uname -s)"
  case "$want:$got" in
    macos:Darwin|linux:Linux) return 0 ;;
    windows:MINGW*|windows:MSYS*|windows:CYGWIN*) return 0 ;;
    *) die "the '$want' target must be built on $want (this host reports $got). Flutter does not cross-compile desktop targets." ;;
  esac
}

# --- the embedded abctl ------------------------------------------------------------------
#
# abctl is BUILT here rather than downloaded from a previous release. On macOS that is not a
# preference: the bundled binary must be the lipo'd universal build AND must carry the same
# Developer ID signature and hardened runtime as the app, or notarization rejects the whole
# bundle. A binary fetched from the GoReleaser job is thin-arch and unsigned, so it fails
# both tests.

build_abctl_macos_universal() {
  have go || die "no go toolchain — needed to build the embedded abctl."
  have lipo || die "no lipo — needed for the universal abctl."
  log "building universal abctl ($VERSION)"
  GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/abctl-arm64" ./cmd/abctl
  GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/abctl-amd64" ./cmd/abctl
  lipo -create -output "$OUT/abctl" "$OUT/abctl-arm64" "$OUT/abctl-amd64"
  rm -f "$OUT/abctl-arm64" "$OUT/abctl-amd64"
}

build_abctl_native() {
  local ext="${1:-}"
  have go || die "no go toolchain — needed to build the embedded abctl."
  log "building abctl ($VERSION)"
  go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/abctl$ext" ./cmd/abctl
}

# --- flutter -------------------------------------------------------------------------------

flutter_build() {
  local target="$1"
  require_flutter
  log "flutter build $target (name=$BUILD_NAME build=$BUILD_NUMBER)"
  ( cd "$GUIDIR" && flutter build "$target" --release \
      --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER" ) 1>&2
}

cmd_check() {
  require_flutter
  log "dart format check"
  ( cd "$GUIDIR" && dart format --output=none --set-exit-if-changed . ) 1>&2
  log "flutter analyze"
  ( cd "$GUIDIR" && flutter analyze ) 1>&2
}

cmd_test() {
  require_flutter
  log "flutter test"
  ( cd "$GUIDIR" && flutter test ) 1>&2
}

# --- macOS ---------------------------------------------------------------------------------

sign_one() {
  local target="$1"
  if [ -n "$CODESIGN_IDENTITY" ]; then
    # --options runtime is REQUIRED for notarization. Without the hardened runtime Apple
    # rejects the submission with "does not have the hardened runtime enabled" and names the
    # nested binary, which is a confusing way to learn about a missing flag.
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$target"
  else
    codesign --force --sign - "$target"
  fi
}

sign_app_macos() {
  local app="$1"
  # INSIDE-OUT, and deliberately NOT `--deep`. --deep is deprecated, and it silently applies
  # the app's own entitlements to every nested binary it finds — which would hand abctl
  # entitlements it has no business holding. Signing each item explicitly also means a
  # failure names the exact file.
  #
  # Order matters: anything nested must be sealed BEFORE the thing containing it, otherwise
  # signing the parent invalidates the child's seal and `codesign --verify --strict` fails.
  log "signing $app (inside-out)"

  # The embedded CLI first — it is the deepest thing we add.
  sign_one "$app/Contents/Resources/abctl"

  # Then Flutter's own frameworks and any plugin bundles. `flutter build macos` already signs
  # these with an ad-hoc or development identity; they must be RE-signed with the Developer ID
  # or notarization rejects the bundle.
  local nested
  while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    sign_one "$nested"
  done < <(find "$app/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \) 2>/dev/null || true)

  # The main executable, then the bundle itself.
  sign_one "$app/Contents/MacOS/$APPNAME"
  sign_one "$app"

  codesign --verify --strict --verbose=2 "$app/Contents/Resources/abctl"
  codesign --verify --deep --strict --verbose=2 "$app"
  if [ -n "$CODESIGN_IDENTITY" ]; then
    log "signed with Developer ID identity: $CODESIGN_IDENTITY"
  else
    warn "ad-hoc signed — this build CANNOT be notarized and will be blocked by Gatekeeper."
  fi
}

require_notary_creds() {
  [ -n "$CODESIGN_IDENTITY" ] || die "APPLE_NOTARIZE is enabled, but no APPLE_CODESIGN_IDENTITY/CODESIGN_IDENTITY is set."
  [ -n "${APPLE_ID:-}" ] || die "APPLE_NOTARIZE is enabled, but APPLE_ID is not set."
  [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] || die "APPLE_NOTARIZE is enabled, but APPLE_APP_SPECIFIC_PASSWORD is not set."
  [ -n "${APPLE_TEAM_ID:-}" ] || die "APPLE_NOTARIZE is enabled, but APPLE_TEAM_ID is not set."
  have xcrun || die "xcrun is required for notarization."
}

# notary_submit <artifact> <tag>: submit ONE artifact and block up to $NOTARY_TIMEOUT.
# ALWAYS dumps `notarytool log` so Apple's verdict is visible in CI — a bare "Invalid" with
# no log is the single most time-wasting failure mode in this pipeline.
#
# Adapted from the SwiftUI app's build script (removed at v0.4.28); the notary flow was the one
# part of it worth keeping, because it encodes Apple's failure modes rather than our own.
notary_submit() {
  local artifact="$1" tag="$2"
  local out="$OUT/notary-$tag.json"
  local rc=0 status="" subid=""
  set +e
  xcrun notarytool submit "$artifact" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --timeout "$NOTARY_TIMEOUT" \
    --output-format json --wait > "$out" 2>"$OUT/notary-$tag.err"
  rc=$?
  set -e
  subid="$(/usr/bin/plutil -extract id raw -o - "$out" 2>/dev/null || true)"
  status="$(/usr/bin/plutil -extract status raw -o - "$out" 2>/dev/null || true)"
  if [ -n "$subid" ]; then
    log "notary log for $tag (submission $subid)"
    xcrun notarytool log "$subid" \
      --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" >&2 || true
  else
    cat "$OUT/notary-$tag.err" >&2 || true
  fi
  [ "$rc" -eq 0 ] && [ "$status" = "Accepted" ] || return 1
  return 0
}

cmd_macos() {
  require_host macos
  mkdir -p "$OUT"
  build_abctl_macos_universal
  flutter_build macos

  local built="$GUIDIR/build/macos/Build/Products/Release/$APPNAME.app"
  [ -d "$built" ] || die "flutter build macos produced no app at $built"

  local app="$OUT/$APPNAME.app"
  rm -rf "$app"
  cp -R "$built" "$app"

  # Embed abctl. Contents/Resources is the correct home for a nested helper executable and is
  # what abgui-flutter/lib/src/abctl/abctl_locator.dart resolves at runtime.
  cp "$OUT/abctl" "$app/Contents/Resources/abctl"
  chmod +x "$app/Contents/Resources/abctl"
  lipo -info "$app/Contents/Resources/abctl" >&2

  sign_app_macos "$app"

  local zip="$OUT/$APPNAME-$VERSION-macos.zip"
  local dmg="$OUT/$APPNAME-$VERSION-macos.dmg"

  # DMG staging: the app plus an /Applications symlink, which is the drag-to-install idiom.
  local staging="$OUT/dmg-staging"
  rm -rf "$staging"; mkdir -p "$staging"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  rm -f "$dmg"
  hdiutil create -volname "$APPNAME $VERSION" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$staging"
  [ -n "$CODESIGN_IDENTITY" ] && codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$dmg"

  rm -f "$zip"
  ( cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "$APPNAME.app" "$zip" )

  log "packaged $dmg"
  log "packaged $zip"

  truthy "$NOTARIZE" && cmd_macos_notarize
  return 0
}

# macos-notarize: notarize + staple the artifacts `macos` ALREADY built, in place.
#
# Split from `macos` so the release can upload the SIGNED assets first and only then wait on
# Apple. Notarization is the one step in this pipeline that depends on a third-party service
# being up; if it stalls, a signed-but-unstapled build is still installable (users get one
# Gatekeeper prompt), whereas a release that fails at this step ships nothing at all. CI marks
# this step continue-on-error for exactly that reason.
cmd_macos_notarize() {
  require_host macos
  require_notary_creds
  local app="$OUT/$APPNAME.app"
  [ -d "$app" ] || die "no $app — run './scripts/build-gui-flutter.sh macos' first"

  # Resolve what `macos` ACTUALLY produced rather than reconstructing the name from VERSION.
  # Belt and braces alongside ABGUI_VERSION: if the two invocations ever disagree again, this
  # notarizes the real artifacts instead of failing, and a mismatch is reported loudly rather
  # than looking like "there was nothing to do".
  local zip dmg
  zip="$(ls -1t "$OUT/$APPNAME-"*-macos.zip 2>/dev/null | head -1 || true)"
  dmg="$(ls -1t "$OUT/$APPNAME-"*-macos.dmg 2>/dev/null | head -1 || true)"
  [ -n "$zip" ] || die "no $OUT/$APPNAME-*-macos.zip — run './scripts/build-gui-flutter.sh macos' first"
  [ -n "$dmg" ] || die "no $OUT/$APPNAME-*-macos.dmg — run './scripts/build-gui-flutter.sh macos' first"
  if [ "$zip" != "$OUT/$APPNAME-$VERSION-macos.zip" ]; then
    warn "notarizing $(basename "$zip"), but this run computed VERSION=$VERSION."
    warn "Set ABGUI_VERSION so both invocations agree — see the note at the top of this script."
  fi

  # Submit both CONCURRENTLY so the release waits on Apple roughly once rather than twice.
  log "submitting app zip + DMG for notarization"
  notary_submit "$zip" app & local app_pid=$!
  notary_submit "$dmg" dmg & local dmg_pid=$!
  local app_rc=0 dmg_rc=0
  wait "$app_pid" || app_rc=$?
  wait "$dmg_pid" || dmg_rc=$?
  [ "$app_rc" -eq 0 ] || die "app zip notarization failed — see the notary log above"
  [ "$dmg_rc" -eq 0 ] || die "DMG notarization failed — see the notary log above"

  # Staple the .app, then RE-zip it: the ticket is written INSIDE the bundle, so the zip made
  # before stapling does not contain it and would still hit Apple's network on first launch —
  # which is the whole thing stapling exists to avoid.
  xcrun stapler staple "$app"
  rm -f "$zip"
  ( cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "$APPNAME.app" "$zip" )
  xcrun stapler staple "$dmg"
  log "notarized + stapled app and DMG"
}

# --- Windows --------------------------------------------------------------------------------

cmd_windows() {
  require_host windows
  mkdir -p "$OUT"
  build_abctl_native .exe
  flutter_build windows

  local bundle="$GUIDIR/build/windows/x64/runner/Release"
  [ -d "$bundle" ] || die "flutter build windows produced no bundle at $bundle"

  # Next to abgui.exe: the locator resolves siblings of Platform.resolvedExecutable.
  cp "$OUT/abctl.exe" "$bundle/abctl.exe"

  pack_windows_zip
  warn "unsigned: Windows has no free notarization equivalent, so SmartScreen will warn until an"
  warn "Authenticode/Azure Trusted Signing certificate is configured. See"
  warn "docs/windows-store-and-signing.md."
}

# pack_windows_zip: zip the CURRENT contents of the Flutter Release dir.
#
# Split out of `cmd_windows` so the release can re-pack AFTER Authenticode signing. Signing
# happens in place on the .exe files in that directory, and the installer and the MSIX are both
# built from it afterwards — so they always contained signed binaries. The portable zip did not:
# it was packed in the same breath as the build, i.e. BEFORE the signing step existed in the
# sequence, so it would have shipped unsigned binaries inside a release that had a certificate.
# That is the worst version of the bug, because the release looks signed.
#
# `cmd_windows` still calls this, so a local build and CI keep producing a zip in one command.
# The release calls `windows-zip` again after signing, which simply overwrites it.
pack_windows_zip() {
  require_windows_payload
  local bundle; bundle="$(win_release_dir)"

  local stage="$OUT/$APPNAME-$VERSION-windows"
  rm -rf "$stage"; mkdir -p "$stage"
  cp -R "$bundle"/. "$stage/"
  local zip="$OUT/$APPNAME-$VERSION-windows-x64.zip"
  rm -f "$zip"

  # bsdtar, NOT PowerShell's Compress-Archive.
  #
  # Compress-Archive on Windows PowerShell 5.1 stores entry names with BACKSLASH separators,
  # which the ZIP spec does not allow (APPNOTE 4.4.17.1: forward slashes only). Explorer and
  # Expand-Archive are lenient, so the v0.4.29 artifact did extract correctly on Windows — but
  # `unzip` reads those names as literal filenames, so `data/flutter_assets/` arrives as a pile
  # of files called `data\flutter_assets\…` and the app cannot find its assets.
  #
  # bsdtar ships in System32 on Windows 10 1803+ and on the CI runner, and writes compliant
  # names. Git Bash's own `tar` is GNU tar, which has no `-a`, so the System32 one is named
  # explicitly rather than relying on PATH order.
  local wintar
  wintar="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}\\System32\\tar.exe" 2>/dev/null || echo '/c/Windows/System32/tar.exe')"
  if [ -x "$wintar" ] && "$wintar" --version 2>/dev/null | grep -q bsdtar; then
    # `*` rather than `./*`: the latter stores every entry with a leading "./", which is legal
    # but shows up as a stray "." folder in some extractors.
    ( cd "$stage" && "$wintar" -a -c -f "$zip" * )
  else
    warn "bsdtar not found — falling back to Compress-Archive, which writes non-standard"
    warn "backslash paths. The zip will work on Windows but not with strict extractors."
    ( cd "$OUT" && powershell -NoProfile -Command \
        "Compress-Archive -Path '$APPNAME-$VERSION-windows/*' -DestinationPath '$(basename "$zip")' -Force" )
  fi
  rm -rf "$stage"
  log "packaged $zip"
}

# windows-zip: repack the portable zip from what is on disk now — nothing is rebuilt.
cmd_windows_zip() {
  require_host windows
  mkdir -p "$OUT"
  pack_windows_zip
}

# --- Windows: installer + Store package -------------------------------------------------------
#
# Both operate on the Release directory `windows` ALREADY produced, and neither rebuilds. That
# is not just speed: the release job signs abgui.exe and abctl.exe IN PLACE between `windows`
# and these two steps, so a rebuild here would quietly ship an installer and a Store package
# containing UNSIGNED copies of the binaries the zip had signed. The three artifacts must be
# three wrappers around one payload.

# The directory `flutter build windows` writes, and the one all three artifacts package.
win_release_dir() { printf '%s\n' "$GUIDIR/build/windows/x64/runner/Release"; }

# require_windows_payload: fail with an actionable message if `windows` has not run, or ran
# without embedding the CLI.
#
# The abctl.exe check is the important one. A bundle missing abgui.exe is obviously broken; a
# bundle missing abctl.exe INSTALLS and LAUNCHES and then fails on the first command with
# AbctlMissingBinary, which reads like a user's machine being wrong rather than the build being
# wrong. Airclone shipped several releases with an engine-less installer behind exactly that
# gap, because the bundling step was allowed to fail quietly.
require_windows_payload() {
  local rel; rel="$(win_release_dir)"
  [ -d "$rel" ] || die "no $rel — run './scripts/build-gui-flutter.sh windows' first."
  [ -f "$rel/$APPNAME.exe" ] || die "no $APPNAME.exe in $rel — the Flutter build did not complete."
  [ -f "$rel/abctl.exe" ] || die \
    "abctl.exe is not in $rel. The GUI is a facade over the CLI and does nothing without it; './scripts/build-gui-flutter.sh windows' is what copies it there. Refusing to package a CLI-less artifact."
}

# winpath <unix path>: the same path as a native Windows tool sees it.
#
# ISCC.exe and dart.exe are native binaries; they cannot open "/d/git/abcli/bin". MSYS would
# normally translate arguments on the way through, but that translation is exactly what we turn
# OFF below, so the conversion is done explicitly and visibly instead.
winpath() {
  if have cygpath; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# find_iscc: print a path to Inno Setup 6's command-line compiler, or return 1.
#
# The install location depends on how it was installed and there is no registry-free way to ask:
# `winget install JRSoftware.InnoSetup` lands PER-USER in %LOCALAPPDATA%\Programs, while
# `choco install innosetup` and the classic installer land in Program Files (x86). CI hits the
# second, a developer box usually the first — checking only one is why "works in CI, missing
# locally" (or the reverse) is the default experience with this tool.
find_iscc() {
  if have iscc; then command -v iscc; return 0; fi
  if have ISCC; then command -v ISCC; return 0; fi
  local dir candidate
  # `ProgramFiles(x86)` is not a legal shell identifier, so it can only be read via printenv.
  for dir in \
    "${LOCALAPPDATA:-}/Programs" \
    "$(printenv 'ProgramFiles(x86)' 2>/dev/null || true)" \
    "${PROGRAMFILES:-}" \
    "/c/Program Files (x86)" \
    "/c/Program Files"; do
    [ -n "$dir" ] || continue
    candidate="$(cygpath -u "$dir" 2>/dev/null || printf '%s\n' "$dir")/Inno Setup 6/ISCC.exe"
    if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

# windows-installer: compile abgui-flutter/windows/installer/abgui.iss into bin/.
cmd_windows_installer() {
  require_host windows
  require_windows_payload
  mkdir -p "$OUT"

  local iscc
  iscc="$(find_iscc)" || die \
    "no Inno Setup 6 compiler (ISCC.exe) on this machine. Install it with 'winget install JRSoftware.InnoSetup' or 'choco install innosetup -y', then re-run. The zip from './scripts/build-gui-flutter.sh windows' is unaffected — only the .exe installer needs this."

  local iss="$GUIDIR/windows/installer/$APPNAME.iss"
  [ -f "$iss" ] || die "no $iss"

  # BUILD_NAME, not VERSION: Inno derives the installer's VersionInfo from AppVersion, and
  # `git describe` output like "v0.4.27-3-gabc1234" is not a version number. BUILD_NAME is
  # already normalised to x.y.z for exactly this class of tool (see the header).
  log "Inno Setup: $APPNAME-setup-x64.exe ($BUILD_NAME) with $iscc"

  # MSYS argument translation OFF for this call.
  #
  # Git Bash rewrites arguments that look like POSIX paths before handing them to a native
  # .exe, and every switch ISCC takes starts with a slash: `/DAppVersion=0.4.27` comes out the
  # other side as something like `D:\Git\DAppVersion=0.4.27`, and ISCC then reports a missing
  # or unreadable script rather than a bad switch. Both variables are needed — MSYS2_ARG_CONV_EXCL
  # is the MSYS2 runtime's, MSYS_NO_PATHCONV is Git-for-Windows' — and paths are converted by
  # `winpath` above instead.
  MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 "$iscc" \
    "/DAppVersion=$BUILD_NAME" \
    "/DSourceDir=$(winpath "$(win_release_dir)")" \
    "/O$(winpath "$OUT")" \
    "$(winpath "$iss")" 1>&2

  local setup="$OUT/$APPNAME-setup-x64.exe"
  [ -f "$setup" ] || die "ISCC reported success but produced no $setup"
  log "packaged $setup"
}

# windows-msix: the Microsoft Store package.
#
# `--build-windows false` is what makes this repackage rather than rebuild (see the section
# header). `--store` produces an UNSIGNED, Partner-Center-uploadable package that Microsoft
# signs on ingestion — no certificate and no interactive prompt in CI. For a locally
# INSTALLABLE test package, run `dart run msix:create` in abgui-flutter/ instead: pubspec's
# `store: false` makes it test-sign one.
#
# Identity comes from the environment, not pubspec, because Package/Identity/Publisher is a
# Partner-Center-assigned GUID and this repo is public. See the msix_config block in
# abgui-flutter/pubspec.yaml and docs/windows-store-and-signing.md.
cmd_windows_msix() {
  require_host windows
  require_flutter
  # Deliberately BEFORE anything else: an MSIX whose payload has no abctl.exe is a Store
  # package for an app that cannot run a command. CI marks this step continue-on-error, so
  # dying here costs the (optional) Store lane for one tag instead of shipping a broken one.
  require_windows_payload
  mkdir -p "$OUT"

  # Assemble the identity overrides. A missing variable is LOUD but not fatal: the package
  # still builds — useful for testing the payload — and simply is not submittable. Silence
  # here is how a placeholder-identity package gets uploaded and rejected.
  local identity=() missing=() name
  for name in MSIX_IDENTITY_NAME MSIX_PUBLISHER MSIX_DISPLAY_NAME; do
    local value="${!name:-}"
    if [ -z "$value" ]; then
      missing+=("$name")
      continue
    fi
    case "$name" in
      MSIX_IDENTITY_NAME) identity+=(--identity-name "$value") ;;
      MSIX_PUBLISHER)     identity+=(--publisher "$value") ;;
      MSIX_DISPLAY_NAME)  identity+=(--display-name "$value") ;;
    esac
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    gha_warning "MSIX identity variable(s) not set: ${missing[*]}. The package carries the pubspec PLACEHOLDER identity and Partner Center WILL reject it (package acceptance validation). Set them under Settings → Secrets and variables → Actions → Variables; see docs/windows-store-and-signing.md."
  else
    log "MSIX identity supplied from the environment (name + publisher + display name)"
  fi

  # x.y.z.0 — four parts, and the Store reserves the last one, so it must be 0. BUILD_NAME is
  # the same normalised version the installer gets, which keeps the two artifacts from a single
  # tag claiming different versions.
  log "dart run msix:create --store ($BUILD_NAME.0)"
  ( cd "$GUIDIR" && dart run msix:create \
      --store \
      --build-windows false \
      --version "$BUILD_NAME.0" \
      --output-path "$(winpath "$OUT")" \
      --output-name "$APPNAME-$VERSION-windows-x64" \
      "${identity[@]}" ) 1>&2

  local msix="$OUT/$APPNAME-$VERSION-windows-x64.msix"
  [ -f "$msix" ] || die "msix:create reported success but produced no $msix"
  log "packaged $msix"
}

# --- Linux ----------------------------------------------------------------------------------

cmd_linux() {
  require_host linux
  mkdir -p "$OUT"
  build_abctl_native
  flutter_build linux

  local bundle="$GUIDIR/build/linux/x64/release/bundle"
  [ -d "$bundle" ] || die "flutter build linux produced no bundle at $bundle"

  cp "$OUT/abctl" "$bundle/abctl"
  chmod +x "$bundle/abctl"

  # AppImage ONLY. A tarball of the same bundle used to ship beside it and was pure redundancy:
  # the AppImage is one file, needs no root and no package manager, runs on any distro, and
  # `--appimage-extract` recovers exactly the tarball's contents for anyone who wanted the raw
  # tree. Two artifacts that differ only in convenience make a release page ask a question.
  make_appimage "$bundle"

  # The glibc floor of the AppImage is the BUILDER's, not Flutter's. Built on a modern
  # runner it simply will not start on Debian 12 / Ubuntu 22.04 ("GLIBC_2.38 not found").
  # An AppImage bundles the GTK stack but NOT glibc, so "runs on any distro" is only true
  # because CI pins ubuntu-22.04 for this job. Keep it pinned.
  warn "glibc floor = this builder's. Build on the oldest distro you intend to support."
}

# make_appimage <flutter-bundle-dir>: a single self-contained executable file.
#
# AppImage rather than .deb, deliberately. A .deb obliges us to declare a runtime dependency
# list that is right on Debian and wrong somewhere else forever, and it only serves the
# Debian/Ubuntu family. One file that runs anywhere, needs no root and no package manager, is
# the better trade for a tool whose Linux users are not a known population.
make_appimage() {
  local bundle="$1"
  local appdir="$OUT/$APPNAME.AppDir"
  local outfile="$OUT/$APPNAME-$VERSION-x86_64.AppImage"

  local tool
  tool="$(find_appimagetool)" || {
    warn "no appimagetool and it could not be fetched — skipping the AppImage (the tarball still built)."
    return 0
  }

  rm -rf "$appdir"
  mkdir -p "$appdir/usr/bin" "$appdir/usr/share/applications" \
           "$appdir/usr/share/icons/hicolor/256x256/apps"

  # The whole Flutter bundle goes in usr/bin: the runner resolves data/ and lib/ RELATIVE to
  # its own executable, so splitting them across usr/lib and usr/share breaks asset loading
  # with an error that blames Flutter rather than the packaging.
  cp -R "$bundle"/. "$appdir/usr/bin/"

  # AppImage requires the .desktop file and the icon at the AppDir ROOT, and conventionally
  # also in the usr/share locations so a desktop-integrated install finds them.
  cat > "$appdir/$APPNAME.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=abgui
GenericName=Apple Business Manager GitOps
Comment=Manage Apple Business Manager configurations and blueprints as GitOps
Exec=abgui
Icon=abgui
Categories=Development;System;
Terminal=false
StartupWMClass=abgui
DESKTOP
  cp "$appdir/$APPNAME.desktop" "$appdir/usr/share/applications/"

  local icon="$GUIDIR/assets/icon/abgui.png"
  if [ -f "$icon" ]; then
    cp "$icon" "$appdir/$APPNAME.png"
    cp "$icon" "$appdir/usr/share/icons/hicolor/256x256/apps/$APPNAME.png"
  else
    warn "no $icon — the AppImage will have no icon."
  fi

  # AppRun: the entry point. LD_LIBRARY_PATH must point at the bundle's own lib/ or the app
  # picks up the host's Flutter/plugin sonames if any happen to exist, which fails in ways
  # that look like a corrupt download.
  cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="${HERE}/usr/bin/lib:${LD_LIBRARY_PATH}"
# abctl is embedded beside the app binary; expose it so a user who wants the CLI has it.
export PATH="${HERE}/usr/bin:${PATH}"
exec "${HERE}/usr/bin/abgui" "$@"
APPRUN
  chmod +x "$appdir/AppRun"

  rm -f "$outfile"
  # --appimage-extract-and-run: CI runners have no FUSE, and without this appimagetool cannot
  # even mount ITSELF. ARCH is required or the tool refuses to guess.
  ARCH=x86_64 "$tool" --appimage-extract-and-run "$appdir" "$outfile" >&2
  chmod +x "$outfile"
  rm -rf "$appdir"
  log "packaged $outfile"
}

# find_appimagetool prints a path to appimagetool, fetching it if needed. Cached in bin/.
find_appimagetool() {
  if have appimagetool; then command -v appimagetool; return 0; fi
  local cached="$OUT/appimagetool-x86_64.AppImage"
  if [ -x "$cached" ]; then printf '%s\n' "$cached"; return 0; fi
  have curl || return 1
  log "fetching appimagetool" >&2
  curl -fsSL -o "$cached" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage || return 1
  chmod +x "$cached"
  printf '%s\n' "$cached"
}

cmd_clean() {
  rm -rf "$GUIDIR/build" "$OUT/$APPNAME.app" "$OUT/$APPNAME.AppDir" "$OUT/$APPNAME-"*-macos.* \
         "$OUT/$APPNAME-"*-windows-*.zip "$OUT/$APPNAME-"*-windows-*.msix \
         "$OUT/$APPNAME-setup-x64.exe" "$OUT/$APPNAME-"*-linux-*.tar.gz \
         "$OUT/$APPNAME-"*-x86_64.AppImage "$OUT/notary-"*
  log "cleaned"
}

case "${1:-}" in
  check)             cmd_check ;;
  test)              cmd_test ;;
  macos)             cmd_macos ;;
  macos-notarize)    cmd_macos_notarize ;;
  windows)           cmd_windows ;;
  windows-zip)       cmd_windows_zip ;;
  windows-installer) cmd_windows_installer ;;
  windows-msix)      cmd_windows_msix ;;
  linux)             cmd_linux ;;
  clean)             cmd_clean ;;
  *) die "usage: $0 {check|test|macos|macos-notarize|windows|windows-zip|windows-installer|windows-msix|linux|clean}" ;;
esac
