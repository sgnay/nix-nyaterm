#!/usr/bin/env bash
# Bump the pinned NyaTerm upstream release and refresh every fixed-output hash.
#
# The source stays pinned to a release tag so builds remain reproducible; this
# script is the only thing that needs to run when a new NyaTerm release lands.
#
# Usage:
#   scripts/update-upstream.sh            update the working tree, no commit
#   scripts/update-upstream.sh --commit   update and commit the result
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UPSTREAM_SLUG="nyakang/nyaterm"
UPSTREAM_URL="https://github.com/${UPSTREAM_SLUG}"
FLAKE="${ROOT}/flake.nix"
PKG="${ROOT}/nix/package.nix"
BUILD_TARGET=".#nyaterm"
MAX_HASH_ROUNDS=5
COMMIT_PATHS=(flake.nix flake.lock nix/package.nix)
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

DO_COMMIT=0
[ "${1:-}" = "--commit" ] && DO_COMMIT=1

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

current_pin() {
  sed -n 's|.*github:'"${UPSTREAM_SLUG}"'/\(v[^"]*\)".*|\1|p' "$FLAKE" | head -1
}

# Stable releases on the same major.minor line, e.g. v1.2.12. Pre-releases and
# other release lines are excluded on purpose.
latest_in_line() {
  local line=$1
  git ls-remote --tags --refs "$UPSTREAM_URL" 2>/dev/null |
    awk '{ sub("refs/tags/", "", $2); print $2 }' |
    grep -E "^${line//./\\.}\.[0-9]+$" |
    sort -V |
    tail -1
}

newer_lines() {
  local line=$1
  {
    printf '%s\n' "$line"
    git ls-remote --tags --refs "$UPSTREAM_URL" 2>/dev/null |
      awk '{ sub("refs/tags/", "", $2); print $2 }' |
      grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
      sed -E 's|^v([0-9]+)\.([0-9]+)\.[0-9]+$|v\1.\2|'
  } | sort -uV | awk -v cur="$line" '$0 == cur { seen = 1; next } seen'
}

# Rewrite the tag inside the fetchPnpmDeps block; fall back to the file's only
# declared hash when upstream introduces a differently named fetch.
set_pnpm_hash() {
  local new=$1 line
  line=$(awk '
    /fetchPnpmDeps[[:space:]]*\{/ { in_block = 1 }
    in_block && /hash[[:space:]]*=[[:space:]]*"sha256-/ { print NR; exit }
  ' "$PKG")
  if [ -z "$line" ]; then
    mapfile -t candidates < <(grep -n 'hash[[:space:]]*=[[:space:]]*"sha256-' "$PKG" | cut -d: -f1)
    [ "${#candidates[@]}" -eq 1 ] || return 1
    line=${candidates[0]}
  fi
  sed -i "${line}s|hash[[:space:]]*=[[:space:]]*\"sha256-[^\"]*\"|hash = \"${new}\"|" "$PKG"
}

pin=$(current_pin)
[ -n "$pin" ] || die "could not read the nyaterm-src tag from flake.nix"
line=$(printf '%s' "$pin" | sed -E 's/^(v[0-9]+\.[0-9]+)\..*/\1/')
log "pinned release: ${pin} (${line} line)"

log "querying upstream tags at ${UPSTREAM_SLUG}"
latest=$(latest_in_line "$line")
[ -n "$latest" ] || die "no stable ${line}.x release found upstream"

others=$(newer_lines "$line")
if [ -n "$others" ]; then
  warn "upstream also has newer release lines: $(printf '%s' "$others" | tr '\n' ' ')"
  warn "a new major/minor line is not a hash bump - nix/package.nix must be reviewed by hand first"
fi

if [ "$latest" = "$pin" ]; then
  log "${pin} is already the newest ${line}.x release"
elif [ "$(printf '%s\n%s\n' "$pin" "$latest" | sort -V | tail -1)" = "$pin" ]; then
  log "${pin} is ahead of upstream's newest ${line}.x release (${latest}); keeping the pin"
else
  log "bumping ${pin} -> ${latest}"
  sed -i "s|github:${UPSTREAM_SLUG}/${pin}|github:${UPSTREAM_SLUG}/${latest}|" "$FLAKE"
fi

log "refreshing flake.lock"
(cd "$ROOT" && nix flake update nyaterm-src >/dev/null)

# Build, adopting each hash Nix reports until the build is clean. Fails loudly on
# any other build error so a genuine break is never papered over.
built=0
for round in $(seq 1 "$MAX_HASH_ROUNDS"); do
  log "building ${BUILD_TARGET} (attempt ${round}/${MAX_HASH_ROUNDS})"
  if (cd "$ROOT" && nix build "$BUILD_TARGET" -L) >"$LOG" 2>&1; then
    built=1
    break
  fi

  got=$(grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' "$LOG" | head -1 | awk '{print $2}')
  if [ -z "$got" ]; then
    cat "$LOG" >&2
    die "build failed for a reason other than a fixed-output hash mismatch"
  fi

  specified=$(grep -oE 'specified:[[:space:]]+sha256-[A-Za-z0-9+/=]+' "$LOG" | head -1 | awk '{print $2}')
  log "hash mismatch (${specified} -> ${got}); updating nix/package.nix"
  set_pnpm_hash "$got" || die "cannot map the reported hash onto a source in nix/package.nix"
done

[ "$built" -eq 1 ] || die "gave up after ${MAX_HASH_ROUNDS} hash rounds"

for f in bin/nyaterm bin/nyaterm-mcp share/applications/nyaterm.desktop; do
  [ -e "${ROOT}/result/$f" ] || die "expected output missing: result/$f"
done

log "build OK, package outputs verified"

if [ "$DO_COMMIT" -eq 1 ]; then
  if [ -n "$(git -C "$ROOT" status --porcelain -- "${COMMIT_PATHS[@]}")" ]; then
    log "committing"
    git -C "$ROOT" add "${COMMIT_PATHS[@]}"
    git -C "$ROOT" commit -q -m "chore(nix): update NyaTerm to ${latest}"
    log "committed"
  else
    log "nothing to commit"
  fi
else
  log "working tree updated; review and commit it yourself"
fi