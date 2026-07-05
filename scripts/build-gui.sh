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

GUIDIR="$repo/abgui"
APP="$repo/bin/abgui.app"
PKG="abgui" # SwiftPM executable target → binary name
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
LDFLAGS="-s -w -X github.com/GigaionLLC/abcli/internal/cli.version=$VERSION"

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
  [ -f "$GUIDIR/Resources/AppIcon.icns" ] && cp "$GUIDIR/Resources/AppIcon.icns" "$APP/Contents/Resources/"
  printf 'APPL????' > "$APP/Contents/PkgInfo"

  # Ad-hoc sign inside-out (nested binary first) — an Apple-Silicon Mach-O needs at least
  # an ad-hoc signature to execute. NOT Developer ID / notarized (see design §6.1).
  codesign -s - --force "$APP/Contents/Resources/abctl"
  codesign -s - --force "$APP/Contents/MacOS/abgui"
  codesign -s - --force "$APP"
  log "assembled $APP  (abctl $VERSION embedded, unsigned/ad-hoc)"
}

write_run_note() {
  cat > "$repo/docs/HOW-TO-RUN-UNSIGNED.txt" <<'EOF'
abgui — running this unsigned build
===================================

This build is ad-hoc signed but NOT notarized (no Apple Developer account), so macOS
quarantines it on first download. One-time setup:

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

cmd_test() { require_macos; log "swift test"; swift test --package-path "$GUIDIR"; }
cmd_build() { require_macos; do_swift_build debug; log "built abgui (debug)"; }
cmd_app() { assemble; }
cmd_run() { assemble; log "launching abgui"; open "$APP"; }

cmd_zip() {
  assemble
  write_run_note
  local zip="$repo/bin/abgui-$VERSION-macos.zip"
  rm -f "$zip"
  ( cd "$repo/bin" && ditto -c -k --sequesterRsrc --keepParent "abgui.app" "$zip" )
  log "packaged $zip"
  log "run note → docs/HOW-TO-RUN-UNSIGNED.txt"
}

cmd_clean() {
  rm -rf "$GUIDIR/.build" "$APP"
  rm -f "$repo"/bin/abgui-*-macos.zip
  log "cleaned abgui build products"
}

case "${1:-}" in
  test)  cmd_test ;;
  build) cmd_build ;;
  app)   cmd_app ;;
  run)   cmd_run ;;
  zip)   cmd_zip ;;
  clean) cmd_clean ;;
  ""|-h|--help) printf 'usage: build-gui.sh {test|build|app|run|zip|clean}\n' >&2 ;;
  *) die "unknown command: '$1' (want test|build|app|run|zip|clean)" ;;
esac
