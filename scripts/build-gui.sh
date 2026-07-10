#!/usr/bin/env bash
#
# scripts/build-gui.sh — build abgui (the macOS Swift GUI) and assemble a self-contained,
# UNSIGNED abgui.app with a universal abctl EMBEDDED inside it. macOS only, credential-free
# (it never touches a tenant), so it is kept separate from scripts/pipeline.sh but adopts
# the same idioms. See docs/abgui-design.md §6-§7.
#
#   ./scripts/build-gui.sh test    # swift test (offline, no credentials)
#   ./scripts/build-gui.sh build   # compile the Swift app (debug)
#   ./scripts/build-gui.sh app     # assemble bin/abgui.app (embeds a universal abctl)
#   ./scripts/build-gui.sh run     # assemble + launch
#   ./scripts/build-gui.sh zip     # assemble + package bin/abgui-<ver>-macos.zip + run note
#   ./scripts/build-gui.sh dmg     # assemble + a drag-to-Applications installer .dmg
#   ./scripts/build-gui.sh dist    # assemble once → both the .dmg installer and the .zip (release)
#   ./scripts/build-gui.sh clean

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
truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

GUIDIR="$repo/abgui"
APP="$repo/bin/abgui.app"
PKG="abgui" # SwiftPM executable target → binary name
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
LDFLAGS="-s -w -X github.com/GigaionLLC/abcli/internal/cli.version=$VERSION"
CODESIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
NOTARIZE="${APPLE_NOTARIZE:-${NOTARIZE:-0}}"
# Per-submission wall-clock cap for `notarytool submit --wait`, so a stuck Apple
# submission fails fast with diagnostics instead of hanging until the CI job SIGKILL.
NOTARY_TIMEOUT="${APPLE_NOTARY_TIMEOUT:-20m}"
# Extra attempts, used ONLY when an upload never registered with Apple (5xx/network).
NOTARY_RETRIES="${APPLE_NOTARY_RETRIES:-2}"
# A failed submit is retried ONLY if it failed FAST (upload/network error, seconds). Any
# attempt that ran at least this many seconds is a polling timeout and is NEVER re-uploaded,
# so worst-case notary wall-clock stays ~NOTARY_TIMEOUT + brief retries — under the CI cap.
NOTARY_RETRY_WINDOW="${APPLE_NOTARY_RETRY_WINDOW:-120}"

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "abgui builds on macOS only (this host is $(uname -s))."
  have swift || die "no swift toolchain — install Xcode or the Command Line Tools (xcode-select --install)."
}

# do_swift_build compiles (build chatter to stderr so stdout stays clean for callers).
# Release builds are universal (arm64 + x86_64) in one shot.
do_swift_build() {
  local config="$1"
  local args=(-c "$config" --package-path "$GUIDIR")
  [ "$config" = "release" ] && args+=(--arch arm64 --arch x86_64)
  log "swift build ($config)"
  swift build "${args[@]}" 1>&2
}

# swift_bin_path prints ONLY the product dir for a config (no build).
swift_bin_path() {
  local config="$1"
  local args=(-c "$config" --package-path "$GUIDIR" --show-bin-path)
  [ "$config" = "release" ] && args+=(--arch arm64 --arch x86_64)
  swift build "${args[@]}"
}

build_universal_abctl() {
  have go || die "no go toolchain — needed to build the embedded abctl."
  log "building universal abctl ($VERSION)"
  GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "$LDFLAGS" -o "$repo/bin/abctl-arm64" ./cmd/abctl
  GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "$LDFLAGS" -o "$repo/bin/abctl-amd64" ./cmd/abctl
  lipo -create -output "$repo/bin/abctl" "$repo/bin/abctl-arm64" "$repo/bin/abctl-amd64"
  rm -f "$repo/bin/abctl-arm64" "$repo/bin/abctl-amd64"
}

sign_one() {
  local target="$1"
  if [ -n "$CODESIGN_IDENTITY" ]; then
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$target"
  else
    codesign --force --sign - "$target"
  fi
}

verify_signature() {
  local target="$1"
  codesign --verify --strict --verbose=2 "$target"
}

sign_app() {
  # Sign inside-out; avoid deprecated --deep so every executable has an explicit signature.
  sign_one "$APP/Contents/Resources/abctl"
  sign_one "$APP/Contents/MacOS/abgui"
  sign_one "$APP"
  verify_signature "$APP/Contents/Resources/abctl"
  verify_signature "$APP/Contents/MacOS/abgui"
  verify_signature "$APP"
  if [ -n "$CODESIGN_IDENTITY" ]; then
    log "signed $APP with Developer ID identity: $CODESIGN_IDENTITY"
  else
    log "ad-hoc signed $APP"
  fi
}

sign_dmg() {
  local dmg="$1"
  [ -n "$CODESIGN_IDENTITY" ] || return 0
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$dmg"
  verify_signature "$dmg"
  log "signed $dmg with Developer ID identity"
}

require_notary_creds() {
  [ -n "$CODESIGN_IDENTITY" ] || die "APPLE_NOTARIZE is enabled, but no APPLE_CODESIGN_IDENTITY/CODESIGN_IDENTITY is set."
  [ -n "${APPLE_ID:-}" ] || die "APPLE_NOTARIZE is enabled, but APPLE_ID is not set."
  [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] || die "APPLE_NOTARIZE is enabled, but APPLE_APP_SPECIFIC_PASSWORD is not set."
  [ -n "${APPLE_TEAM_ID:-}" ] || die "APPLE_NOTARIZE is enabled, but APPLE_TEAM_ID is not set."
  have xcrun || die "xcrun is required for notarization."
}

# notary_submit <artifact> <tag>: submit ONE artifact and block up to $NOTARY_TIMEOUT.
# Captures the submission id from JSON, ALWAYS runs `notarytool log` so Apple's verdict
# is visible in CI, and exits non-zero on any non-Accepted status or timeout — so a stuck
# submission fails fast with diagnostics instead of hanging to the job SIGKILL. Retries
# ONLY when the upload never registered with Apple (transient 5xx/network), detected as a
# FAST failure (< NOTARY_RETRY_WINDOW seconds); a real verdict (Rejected/Invalid) or a
# polling timeout is never re-uploaded — even when notarytool's timeout output carries no
# submission id, the elapsed-time guard prevents a re-upload. Safe to run backgrounded (&).
notary_submit() {
  local artifact="$1" tag="$2"
  local out="$repo/bin/notary-$tag.json" err="$repo/bin/notary-$tag.err"
  local attempt=1 rc=0 status="" subid="" started=0 elapsed=0
  while :; do
    rm -f "$out" "$err"
    started=$SECONDS
    set +e
    xcrun notarytool submit "$artifact" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --timeout "$NOTARY_TIMEOUT" \
      --wait \
      --output-format json >"$out" 2>"$err"
    rc=$?
    set -e
    elapsed=$((SECONDS - started))
    subid="$(/usr/bin/plutil -extract id raw -o - "$out" 2>/dev/null || true)"
    [ -n "$subid" ] || subid="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$out" 2>/dev/null | head -n1 || true)"
    status="$(/usr/bin/plutil -extract status raw -o - "$out" 2>/dev/null || true)"
    [ -n "$status" ] || status="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$out" 2>/dev/null | head -n1 || true)"

    if [ "$rc" -eq 0 ] && [ "$status" = "Accepted" ]; then
      break                       # success
    elif [ -n "$subid" ]; then
      break                       # registered but Rejected/Invalid/timed out — report, do NOT re-upload
    elif [ "$elapsed" -ge "$NOTARY_RETRY_WINDOW" ]; then
      break                       # ran long → polling timeout, NOT a failed upload; never re-upload
    elif [ "$attempt" -ge "$((NOTARY_RETRIES + 1))" ]; then
      break                       # exhausted retries for an upload that never registered
    fi
    warn "notarize $tag: submit failed fast without registering (attempt $attempt, rc=$rc, ${elapsed}s) — retrying after backoff"
    attempt=$((attempt + 1))
    sleep $((attempt * 15))
  done

  if [ -n "$subid" ]; then
    log "notary $tag: submission $subid → status ${status:-unknown}"
    xcrun notarytool log "$subid" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" >&2 || warn "notarize $tag: could not fetch notary log for $subid"
  else
    warn "notarize $tag: no submission id captured after ${elapsed}s — raw notarytool output follows"
    warn "notarize $tag: check \`xcrun notarytool history\` for this team to see if the submission registered"
    cat "$out" "$err" >&2 2>/dev/null || true
  fi

  [ "$status" = "Accepted" ] || die "notarize $tag: not Accepted (status ${status:-none}, rc $rc, last attempt ${elapsed}s)"
}

# build_app_notary_zip prints the path to a fresh zip of bin/abgui.app for notarytool.
build_app_notary_zip() {
  local app_zip="$repo/bin/abgui-$VERSION-app-notary.zip"
  rm -f "$app_zip"
  ( cd "$repo/bin" && ditto -c -k --keepParent "abgui.app" "$app_zip" )
  printf '%s\n' "$app_zip"
}

# notarize_app_only: notarize + staple just bin/abgui.app (the zip-only path).
notarize_app_only() {
  truthy "$NOTARIZE" || return 0
  require_notary_creds
  local app_zip; app_zip="$(build_app_notary_zip)"
  log "submitting $APP for Apple notarization"
  notary_submit "$app_zip" app
  xcrun stapler staple "$APP"; xcrun stapler validate "$APP"
  rm -f "$app_zip"
  log "notarized + stapled $APP"
}

# notarize_dmg_only: notarize + staple just the DMG (the dmg-only path).
notarize_dmg_only() {
  local dmg="$1"
  truthy "$NOTARIZE" || return 0
  require_notary_creds
  [ -f "$dmg" ] || die "notarize_dmg_only: no DMG at $dmg"
  log "submitting $dmg for Apple notarization"
  notary_submit "$dmg" dmg
  xcrun stapler staple "$dmg"; xcrun stapler validate "$dmg"
  log "notarized + stapled $dmg"
}

# notarize_release: submit the app zip AND the DMG CONCURRENTLY (one wall-clock wait,
# not the sum of two), then staple both. The .app is stapled before it is zipped by
# make_zip; the DMG is stapled after it is notarized.
notarize_release() {
  local dmg="$1"
  truthy "$NOTARIZE" || return 0
  require_notary_creds
  [ -f "$dmg" ] || die "notarize_release: no DMG at $dmg"
  local app_zip; app_zip="$(build_app_notary_zip)"
  local app_pid dmg_pid app_rc=0 dmg_rc=0

  log "submitting app zip + DMG for Apple notarization (concurrent)"
  notary_submit "$app_zip" app &
  app_pid=$!
  notary_submit "$dmg" dmg &
  dmg_pid=$!
  wait "$app_pid" || app_rc=$?
  wait "$dmg_pid" || dmg_rc=$?
  [ "$app_rc" -eq 0 ] || die "app notarization failed (rc $app_rc) — see notary log above"
  [ "$dmg_rc" -eq 0 ] || die "DMG notarization failed (rc $dmg_rc) — see notary log above"

  xcrun stapler staple "$APP"; xcrun stapler validate "$APP"   # .app → packaged by make_zip
  xcrun stapler staple "$dmg"; xcrun stapler validate "$dmg"
  rm -f "$app_zip"
  log "notarized + stapled app + DMG"
}

# make_icns builds AppIcon.icns from the master PNG (macOS: sips + iconutil) into the
# given Resources dir. No-op (with a note) if the master or the tools are missing.
make_icns() {
  local resources="$1"
  local master="$GUIDIR/Resources/AppIcon.png"
  [ -f "$master" ] || { warn "no abgui/Resources/AppIcon.png — the app will use the generic icon."; return 0; }
  have iconutil && have sips || { warn "sips/iconutil not found — skipping the app icon."; return 0; }
  local iconset="$repo/bin/AppIcon.iconset"
  rm -rf "$iconset"
  mkdir -p "$iconset"
  local s
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$master" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$master" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
  rm -rf "$iconset"
  log "built AppIcon.icns (from Resources/AppIcon.png)"
}

# assemble builds the release app + embeds a universal abctl → bin/abgui.app.
assemble() {
  require_macos
  build_universal_abctl
  do_swift_build release
  local bindir exe
  bindir="$(swift_bin_path release)"
  exe="$bindir/$PKG"
  [ -x "$exe" ] || die "swift build produced no executable at $exe"

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$exe" "$APP/Contents/MacOS/abgui"
  sed "s/@VERSION@/$VERSION/g" "$GUIDIR/Packaging/Info.plist" > "$APP/Contents/Info.plist"
  # The embedded engine + attribution travel INSIDE the bundle. abctl is universal.
  cp "$repo/bin/abctl" "$APP/Contents/Resources/abctl"
  cp "$repo/LICENSE" "$repo/NOTICE" "$APP/Contents/Resources/"
  make_icns "$APP/Contents/Resources"
  printf 'APPL????' > "$APP/Contents/PkgInfo"

  # Ad-hoc sign inside-out (nested binary first) — an Apple-Silicon Mach-O needs at least
  # an ad-hoc signature to execute. NOT Developer ID / notarized (see design §6.1).
  sign_app
  log "assembled $APP  (abctl $VERSION embedded)"
}

write_run_note() {
  cat > "$repo/docs/HOW-TO-RUN-UNSIGNED.txt" <<'EOF'
abgui — running this unsigned build
===================================

This build is NOT notarized, so macOS may quarantine it on first download.
One-time setup:

  1. Move abgui.app to /Applications.
  2. Strip the download quarantine (covers the embedded abctl too):
        xattr -dr com.apple.quarantine /Applications/abgui.app
  3. Double-click abgui.app.

If you skip step 2, first launch is blocked; then open:
  System Settings -> Privacy & Security -> "abgui was blocked" -> Open Anyway.

abgui is self-contained: a universal abctl is embedded at Contents/Resources/abctl.
Your credentials are NOT bundled — abgui reuses ~/.abctl/contexts.yaml.
EOF
}

maybe_write_run_note() {
  if truthy "$NOTARIZE"; then
    rm -f "$repo/docs/HOW-TO-RUN-UNSIGNED.txt"
    return 0
  fi
  write_run_note
}

cmd_test() { require_macos; log "swift test"; swift test --package-path "$GUIDIR"; }
cmd_build() { require_macos; do_swift_build debug; log "built abgui (debug)"; }
cmd_app() { assemble; }
cmd_run() { assemble; log "launching abgui"; open "$APP"; }

# make_zip / make_dmg package the ALREADY-assembled bin/abgui.app.
make_zip() {
  local zip="$repo/bin/abgui-$VERSION-macos.zip"
  rm -f "$zip"
  ( cd "$repo/bin" && ditto -c -k --sequesterRsrc --keepParent "abgui.app" "$zip" )
  log "packaged $zip"
}

# make_dmg builds a drag-to-Applications installer DMG (the friendly install path).
make_dmg() {
  have hdiutil || { warn "hdiutil not found — skipping the DMG."; return 0; }
  local staging="$repo/bin/dmg-staging"
  local dmg="$repo/bin/abgui-$VERSION-macos.dmg"
  rm -rf "$staging"
  mkdir -p "$staging"
  cp -R "$APP" "$staging/"
  ln -s /Applications "$staging/Applications" # drag target
  [ -f "$repo/docs/HOW-TO-RUN-UNSIGNED.txt" ] && cp "$repo/docs/HOW-TO-RUN-UNSIGNED.txt" "$staging/How to run (unsigned).txt"
  rm -f "$dmg"
  hdiutil create -volname "abgui $VERSION" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$staging"
  sign_dmg "$dmg"
  # Notarization is decoupled from packaging so a release can notarize the app zip and
  # the DMG concurrently — see notarize_release / cmd_dist.
  log "packaged $dmg  (drag abgui.app → Applications)"
}

cmd_zip() { assemble; maybe_write_run_note; notarize_app_only; make_zip; }
cmd_dmg() { assemble; maybe_write_run_note; make_dmg; notarize_dmg_only "$repo/bin/abgui-$VERSION-macos.dmg"; }
# dist: assemble ONCE, build the DMG + notarize the app zip and DMG CONCURRENTLY, then
# staple both and produce the (stapled) zip — one Apple wait, not two serial ones.
cmd_dist() {
  assemble
  maybe_write_run_note
  make_dmg
  notarize_release "$repo/bin/abgui-$VERSION-macos.dmg"
  make_zip
}

cmd_clean() {
  rm -rf "$GUIDIR/.build" "$APP" "$repo/bin/dmg-staging"
  rm -f "$repo"/bin/abgui-*-macos.zip "$repo"/bin/abgui-*-macos.dmg
  log "cleaned abgui build products"
}

case "${1:-}" in
  test)  cmd_test ;;
  build) cmd_build ;;
  app)   cmd_app ;;
  run)   cmd_run ;;
  zip)   cmd_zip ;;
  dmg)   cmd_dmg ;;
  dist)  cmd_dist ;;
  clean) cmd_clean ;;
  ""|-h|--help) printf 'usage: build-gui.sh {test|build|app|run|zip|dmg|dist|clean}\n' >&2 ;;
  *) die "unknown command: '$1' (want test|build|app|run|zip|dmg|dist|clean)" ;;
esac
