#!/usr/bin/env bash
# Bump the pin to the newest stable NyaTerm release and refresh fixed-output hashes.
#
# The source stays pinned to a release tag so builds remain reproducible; this
# script follows the highest stable vX.Y.Z tag. Pre-release tags are excluded.
#
# Usage:
#   scripts/update-upstream.sh            update the working tree, no commit
#   scripts/update-upstream.sh --commit   update and commit (managed files must be clean)
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
DID_UPDATE=0

DO_COMMIT=0
[ "${1:-}" = "--commit" ] && DO_COMMIT=1

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [ "$DO_COMMIT" -eq 1 ] && [ -n "$(git -C "$ROOT" status --porcelain -- "${COMMIT_PATHS[@]}")" ]; then
  die "--commit requires flake.nix, flake.lock and nix/package.nix to be clean"
fi

current_pin() {
  sed -n 's|.*github:'"${UPSTREAM_SLUG}"'/\(v[^"]*\)".*|\1|p' "$FLAKE" | head -1
}

# Stable semantic-version release tags, across all major/minor lines.
latest_stable() {
  local refs
  refs=$(git ls-remote --tags --refs "$UPSTREAM_URL" 2>/dev/null) || return 1
  printf '%s\n' "$refs" |
    awk '$2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ { sub("^refs/tags/", "", $2); print $2 }' |
    sort -V |
    tail -1
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
log "pinned release: ${pin}"

log "querying stable release tags at ${UPSTREAM_SLUG}"
latest=$(latest_stable) || die "failed to query upstream release tags"
[ -n "$latest" ] || die "no stable vX.Y.Z release tags found upstream"
log "latest stable release: ${latest}"

if [ "$latest" = "$pin" ]; then
  log "${pin} is already the newest stable release"
elif [ "$(printf '%s\n%s\n' "$pin" "$latest" | sort -V | tail -1)" = "$pin" ]; then
  log "${pin} is ahead of upstream's newest stable release (${latest}); keeping the pin"
else
  log "bumping ${pin} -> ${latest}"
  sed -i "s|github:${UPSTREAM_SLUG}/${pin}|github:${UPSTREAM_SLUG}/${latest}|" "$FLAKE"
  DID_UPDATE=1
fi

log "refreshing flake.lock"
lock_before=$(git -C "$ROOT" hash-object "$ROOT/flake.lock")
(cd "$ROOT" && nix flake update nyaterm-src >/dev/null)
lock_after=$(git -C "$ROOT" hash-object "$ROOT/flake.lock")
[ "$lock_before" = "$lock_after" ] || DID_UPDATE=1

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
  DID_UPDATE=1
done

[ "$built" -eq 1 ] || die "gave up after ${MAX_HASH_ROUNDS} hash rounds"

log "verifying package outputs"
system=$(nix eval --impure --raw --expr builtins.currentSystem) \
  || die "could not determine the current system"
(cd "$ROOT" && nix build --no-link ".#checks.${system}.nyaterm" -L) \
  || die "package outputs failed verification"

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
  if [ "$DID_UPDATE" -eq 1 ]; then
    log "working tree updated; review and commit it yourself"
  else
    log "upstream pin unchanged; no updater changes made"
  fi
fi
