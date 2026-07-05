#!/usr/bin/env bash
#
# scripts/pipeline.sh — run abctl's CI/CD pipeline on your own machine, exactly the
# way GitHub Actions / GitLab CI run it. One script, two homes: use it locally on the
# current branch, or let CI call it so the pipeline logic lives in ONE place.
#
#   ./scripts/pipeline.sh ci      # build + gofmt + vet + test (+ lint)  — no secrets
#   ./scripts/pipeline.sh plan    # READ-ONLY: what `sync --apply` would change
#   ./scripts/pipeline.sh drift   # READ-ONLY: exit 3 if git and the tenant diverge
#   ./scripts/pipeline.sh apply   # LIVE, GATED writes (+ optional baseline commit-back)
#   ./scripts/pipeline.sh release # local GoReleaser snapshot (no publish)
#
# Credentials (plan/apply/drift only) resolve exactly as abctl does: an abctl context,
# a .env, or AB_CLIENT_ID + AB_PRIVATE_KEY (a key *file path*) in the environment. As a
# convenience — and to match how CI ships the key — if AB_PRIVATE_KEY_PEM holds the key
# *contents*, it is written to a private temp file for you. Nothing is echoed; the temp
# key is deleted on exit.
#
# Safety: tenant writes happen ONLY under `apply`, which abctl itself gates (type 'yes',
# or set $ABCTL_APPROVE=1 / pass --yes). `--prune` (deletes/detaches) is OFF unless you
# pass it. The gitops/archive/ tree (pre-overwrite LIVE profile bodies — possible
# secrets) is NEVER committed; only gitops/state, lib, and blueprints are.

set -euo pipefail

# ---- locate the repo + basic UX ------------------------------------------------
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  c_r=$'\033[0m'; c_b=$'\033[1m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_e=$'\033[31m'
else
  c_r=""; c_b=""; c_g=""; c_y=""; c_e=""
fi
log()  { printf '%s==>%s %s\n'      "$c_g" "$c_r" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$c_y" "$c_r" "$*" >&2; }
die()  { printf '%serror:%s %s\n'   "$c_e" "$c_r" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

is_ci() { [ "${CI:-}" = "true" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${GITLAB_CI:-}" ]; }

# ---- credentials ---------------------------------------------------------------
KEYFILE=""
cleanup() { [ -n "$KEYFILE" ] && rm -f "$KEYFILE"; return 0; }
trap cleanup EXIT

# In CI, secrets arrive only as env vars; if they're absent, self-skip so forks and
# secret-less repos stay green. Locally we NEVER skip — if creds are missing, abctl
# prints a clear "AB_CLIENT_ID not set" error itself, which is the right feedback.
maybe_skip_ci() {
  if is_ci && { [ -z "${AB_CLIENT_ID:-}" ] || [ -z "${AB_PRIVATE_KEY_PEM:-}${AB_PRIVATE_KEY:-}" ]; }; then
    log "CI without API secrets → self-skipping (stays green)."
    exit 0
  fi
}

# creds_shadowed reports whether abctl will prefer a .env / context over process-env
# AB_* (abctl's resolution order is: context, then .env, then — only if neither — the
# process environment). Used to warn before a supplied AB_* is silently ignored.
creds_shadowed() {
  [ -n "${ABCTL_ENV:-}" ] && [ -e "${ABCTL_ENV}" ] && return 0
  [ -e "$repo/.env" ] && return 0
  [ -n "${ABCTL_CONTEXT:-}" ] && return 0
  local cf="${ABCTL_CONTEXTS:-$HOME/.abctl/contexts.yaml}"
  [ -f "$cf" ] && grep -Eq '^current:[[:space:]]*[^[:space:]#]' "$cf" && return 0
  return 1
}

# Materialize an inline PEM (the CI convention; also handy locally) into a 0600 temp
# file and point AB_PRIVATE_KEY at it. No-op when a key path is already set or when you
# rely on a .env / context (abctl resolves those itself).
prepare_creds() {
  # If you pass process-env creds but a .env/context is in scope, abctl uses the
  # .env/context and IGNORES the process AB_* — surface that, so you never think the
  # inline creds took effect (and never apply against the wrong tenant unknowingly).
  if { [ -n "${AB_CLIENT_ID:-}" ] || [ -n "${AB_PRIVATE_KEY_PEM:-}" ]; } && creds_shadowed; then
    warn "a .env or abctl context is in scope — abctl uses IT and ignores the process"
    warn "  AB_CLIENT_ID / AB_PRIVATE_KEY_PEM you set. Unset the .env/context to use them."
  fi
  if [ -n "${AB_PRIVATE_KEY_PEM:-}" ] && [ -z "${AB_PRIVATE_KEY:-}" ]; then
    KEYFILE="$(mktemp "${TMPDIR:-/tmp}/abctl-key.XXXXXX")" || die "mktemp failed"
    chmod 600 "$KEYFILE"
    printf '%s\n' "$AB_PRIVATE_KEY_PEM" > "$KEYFILE"
    export AB_PRIVATE_KEY="$KEYFILE"
    log "wrote the inline PEM to a private temp file (deleted on exit)."
  fi
}

# ---- build ---------------------------------------------------------------------
BIN=""
build() {
  have go || die "Go toolchain not found on PATH."
  local ver ext
  ver="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
  ext="$(go env GOEXE)" # ".exe" on Windows, "" elsewhere
  BIN="$repo/bin/abctl$ext"
  log "building abctl ($ver)"
  go build -ldflags "-X github.com/GigaionLLC/abcli/internal/cli.version=$ver" -o "$BIN" ./cmd/abctl
}

# ---- ci: fmt + vet + build + test (+ lint) — no secrets ------------------------
cmd_ci() {
  have go || die "Go toolchain not found on PATH (install Go — see go.mod for the version)."
  local race=0
  [ "${RACE:-}" = "1" ] && race=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --race) race=1 ;;
      *) die "ci: unknown argument '$1'" ;;
    esac
    shift
  done

  log "gofmt -l . (formatting check)"
  local bad
  bad="$(gofmt -l . || true)"
  [ -z "$bad" ] || die "not gofmt-clean — run 'gofmt -w .':"$'\n'"$bad"
  log "go vet ./..."
  go vet ./...
  log "go build ./..."
  go build ./...
  if [ "$race" = 1 ]; then
    log "go test -race ./... (needs a C compiler / CGO)"
    go test -race ./...
  else
    log "go test ./... (CI also runs -race — add --race or RACE=1)"
    go test ./...
  fi
  # Lint exactly as CI does. If golangci-lint is absent, install the SAME pinned version
  # the workflows use, so a green local run implies a green CI lint job. Only claim a full
  # pass when lint actually ran — never print a false green.
  local lint_bin=""
  if have golangci-lint; then
    lint_bin="golangci-lint"
  else
    warn "golangci-lint not on PATH — installing the pinned v2.12.2 (matches CI)…"
    if go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2; then
      local gobin
      gobin="$(go env GOBIN)"
      [ -n "$gobin" ] || gobin="$(go env GOPATH)/bin"
      lint_bin="$gobin/golangci-lint"
    fi
  fi
  if [ -n "$lint_bin" ]; then
    log "golangci-lint run ./..."
    "$lint_bin" run ./... # real lint findings abort here (set -e) — as CI does
    log "${c_b}CI checks passed.${c_r}"
  else
    warn "LINT SKIPPED — could not obtain golangci-lint (offline?). CI will still lint on push."
    log "build + gofmt + vet + test passed; ${c_b}lint skipped — not a full CI pass.${c_r}"
  fi
}

# ---- plan: READ-ONLY dry-run (mirrors cd-plan) ---------------------------------
cmd_plan() {
  local strict=0 pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --strict) strict=1 ;;
      *) pass+=("$1") ;;
    esac
    shift
  done

  maybe_skip_ci
  prepare_creds
  build
  log "abctl validate (structural check of the local tree)"
  "$BIN" validate || true
  log "abctl sync --dry-run --exit-on-diff  ${c_b}(READ-ONLY — no writes)${c_r}"
  local code=0
  set +e
  "$BIN" sync --dry-run --exit-on-diff ${pass[@]+"${pass[@]}"}
  code=$?
  set -e
  case "$code" in
    0) log "in sync — nothing pending." ;;
    3) log "changes pending — run '${c_b}./scripts/pipeline.sh apply${c_r}' to reconcile."
       if [ "$strict" = 1 ]; then return 3; fi ;;
    *) die "plan failed (exit $code)" ;;
  esac
  return 0
}

# ---- drift: READ-ONLY, exit 3 on divergence (mirrors cd-drift) -----------------
cmd_drift() {
  maybe_skip_ci
  prepare_creds
  build
  log "abctl sync --dry-run --exit-on-diff  ${c_b}(READ-ONLY)${c_r}"
  local code=0
  set +e
  "$BIN" sync --dry-run --exit-on-diff "$@"
  code=$?
  set -e
  case "$code" in
    0) log "no drift — git and the live tenant agree."; return 0 ;;
    3) warn "DRIFT: git and the live tenant diverge (or git changes are due) — reconcile."
       return 3 ;;
    *) die "drift check failed (exit $code)" ;;
  esac
}

# ---- apply: LIVE, gated writes + optional baseline commit-back (mirrors cd-apply)
cmd_apply() {
  local commit=0 push=0 pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --commit) commit=1 ;;
      --push)   commit=1; push=1 ;;
      *) pass+=("$1") ;; # --prune, --yes, --limit-writes N, --platforms … → abctl
    esac
    shift
  done

  maybe_skip_ci
  prepare_creds
  build
  # In CI, pass abctl's own interactive confirm (a human already approved the protected
  # environment). Locally you type 'yes' at the prompt, or pass --yes.
  if is_ci; then export ABCTL_APPROVE=1; fi
  log "abctl sync --apply  ${c_b}(LIVE writes — gated by abctl)${c_r}"
  local code=0
  set +e
  "$BIN" sync --apply ${pass[@]+"${pass[@]}"}
  code=$?
  set -e

  # Commit the reconciled baseline BEFORE surfacing an error, so a partial apply still
  # persists what succeeded (resumable) — same ordering as the CI job.
  if [ "$commit" = 1 ]; then commit_baseline "$push"; fi

  [ "$code" = 0 ] || die "apply reported errors (exit $code)"
  log "${c_b}apply complete.${c_r}"
  [ -d "$repo/gitops/archive" ] && log "pre-overwrite copies kept in gitops/archive/ (gitignored — never committed)."
  return 0
}

# commit_baseline stages ONLY the desired-state + baseline and commits them. It never
# touches gitops/archive/ (pre-overwrite live bodies can carry tenant secrets).
commit_baseline() {
  local push="$1" p paths=()
  if git check-ignore -q gitops/state 2>/dev/null; then
    warn "gitops/ is gitignored (not adopted) — skipping baseline commit."
    warn "  adopt it first (see docs/cicd.md) to persist the reconciled baseline in git."
    return 0
  fi
  for p in gitops/state gitops/lib gitops/blueprints; do
    [ -e "$p" ] && paths+=("$p")
  done
  [ "${#paths[@]}" -gt 0 ] || { log "no baseline paths present to commit."; return 0; }
  git add -- "${paths[@]}"
  # Scope the diff AND the commit to exactly these paths. `commit -- <paths>` behaves like
  # --only: it writes ONLY them regardless of what else is staged, so nothing can ride
  # along — not unrelated pre-staged work, and crucially never a force-staged
  # gitops/archive/ (pre-overwrite live bodies can carry tenant secrets).
  if git diff --cached --quiet -- "${paths[@]}"; then
    log "no baseline changes to commit."
    return 0
  fi
  git -c user.name="abctl-bot" -c user.email="abctl-bot@users.noreply.github.com" \
    commit -q -m "chore(abctl): reconcile baseline after apply [skip ci]" -- "${paths[@]}"
  log "committed reconciled baseline (gitops/state, lib, blueprints only)."
  if [ "$push" = 1 ]; then
    log "pushing…"
    git push
  fi
}

# ---- release: local GoReleaser snapshot ----------------------------------------
cmd_release() {
  have goreleaser || die "goreleaser not installed — see https://goreleaser.com/install/"
  local publish=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --publish) publish=1 ;;
      *) die "release: unknown argument '$1' (did you mean --publish?)" ;;
    esac
    shift
  done
  if [ "$publish" = 1 ]; then
    log "goreleaser release --clean  ${c_b}(PUBLISH — needs a v* tag + tokens)${c_r}"
    goreleaser release --clean
  else
    log "goreleaser release --snapshot  (local build; skips publish/sign/sbom)"
    goreleaser release --snapshot --clean --skip=publish,sign,sbom
    log "artifacts in dist/ — validate config with 'goreleaser check'."
  fi
}

usage() {
  cat >&2 <<EOF
${c_b}abctl pipeline${c_r} — run the CI/CD flow locally or in CI.

  ${c_b}ci${c_r}        build + gofmt + vet + test (+ golangci-lint)     no secrets
  ${c_b}plan${c_r}      READ-ONLY dry-run: what 'apply' would change     creds
  ${c_b}drift${c_r}     READ-ONLY: exit 3 if git and the tenant diverge  creds
  ${c_b}apply${c_r}     LIVE gated writes; --commit[/--push] baseline    creds
  ${c_b}release${c_r}   local GoReleaser snapshot (--publish for real)   —

Extra flags pass straight through to abctl, e.g.:
  ./scripts/pipeline.sh apply --prune --limit-writes 5
  ./scripts/pipeline.sh apply --yes --commit      # non-interactive + commit baseline
  ./scripts/pipeline.sh plan  --strict            # propagate exit 3 (for scripting)
  ./scripts/pipeline.sh ci    --race              # race detector (needs a C compiler)

Credentials resolve as abctl does (context / .env / AB_CLIENT_ID + AB_PRIVATE_KEY).
If AB_PRIVATE_KEY_PEM holds the key contents, it is written to a private temp file.
See docs/cicd.md for the full CI/CD guide.
EOF
}

main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift || true
  case "$sub" in
    ci)                cmd_ci "$@" ;;
    plan)              cmd_plan "$@" ;;
    drift)             cmd_drift "$@" ;;
    apply)             cmd_apply "$@" ;;
    release)           cmd_release "$@" ;;
    ""|-h|--help|help) usage ;;
    *) usage; die "unknown command: '$sub'" ;;
  esac
}

main "$@"
