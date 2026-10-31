#!/usr/bin/env bash
# Bump the pin to the newest stable NyaTerm release and refresh fixed-output hashes.
#
# The source stays pinned so builds remain reproducible; this script follows the
# highest stable vX.Y.Z tag within the currently pinned major line (v1 stays on
# v1.x.y, v2 on v2.x.y). Pre-release tags are excluded.
#
# A pin that is a full commit SHA on the upstream repository is accepted for the
# window after a change lands on `main` but before the release that carries it.
# Upstream squashes a release before tagging it, so a tag does not usually point
# at the pinned commit, and moving to a release that predates it would revert the
# change the pin exists for. The pin therefore becomes the newest stable tag only
# when a clone of upstream proves that tag contains the commit, and the script
# says so when it cannot; a commit that a tag does point at is normalized to that
# tag, because it is the same source. Any other pin shape - a branch name, a
# partial SHA, another repository, another major line - is a hard error, so a
# green weekly run never hides a pin this script can no longer interpret.
#
# Usage:
#   scripts/update-upstream.sh            update the working tree, no commit
#   scripts/update-upstream.sh --commit   update and commit (managed files must be clean)
#
# `scripts/tests/update-upstream-test.sh` drives the decision logic against a
# throwaway repository with stubbed `git` and `nix`, so it needs no network and no
# build. `UPDATE_UPSTREAM_SKIP_VERIFY=1` lets that harness skip the final output
# verification, whose only job is to notice a package that builds but lost a
# binary; the real runs never set it.
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
# Scratch directory of the history check, removed by the same trap that removes the
# build log so a failure path cannot leave either behind.
SCRATCH_DIR=""
cleanup() { rm -rf "${SCRATCH_DIR:-}" "$LOG"; }
trap cleanup EXIT
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

# The URL of the `nyaterm-src` input, read by Nix itself so the updater does not
# depend on how the input block is formatted. `--impure` is needed only because
# pure evaluation refuses to read flake.nix from the working tree.
current_pin_url() {
  (cd "$ROOT" && nix eval --impure --raw --expr \
    '(import ./flake.nix).inputs.nyaterm-src.url')
}

# The line holding `url = ...` inside the `nyaterm-src` input block. The bump
# rewrites exactly this line, so a commented `--override-input` example elsewhere
# in flake.nix can never be edited by accident. The block must be laid out with
# `nyaterm-src = {` and a `url = ...` on its own line; anything else dies loudly
# instead of guessing.
pin_url_line() {
  awk '
    /^[[:space:]]*nyaterm-src[[:space:]]*=[[:space:]]*\{/ { in_block = 1; next }
    in_block && /^[[:space:]]*};?[[:space:]]*$/ { exit }
    in_block && /^[[:space:]]*url[[:space:]]*=/ { print NR; exit }
  ' "$FLAKE"
}

# Stable semantic-version release tags for one major line, so a v1 pin is never
# silently moved to a v2 rewrite with a different source layout.
latest_stable() {
  local major=$1 refs
  refs=$(git ls-remote --tags --refs "$UPSTREAM_URL" 2>/dev/null) || return 1
  printf '%s\n' "$refs" |
    awk -v prefix="v${major}." '
      $2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ {
        sub("^refs/tags/", "", $2)
        if (index($2, prefix) == 1) print $2
      }
    ' |
    sort -V |
    tail -1
}

# The commit a release tag points at. An annotated tag is listed twice by
# `git ls-remote` (the tag object and its peeled `^{}` entry), so the peeled
# entry wins. Only a commit pin needs this, and that path fills in TAG_REFS.
tag_commit() {
  printf '%s\n' "${TAG_REFS:-}" | awk -v tag="refs/tags/$1" '
    $2 == tag "^{}" { peeled = $1 }
    $2 == tag { plain = $1 }
    END { print (peeled != "" ? peeled : plain) }
  '
}

# Rewrite the fixed-output hash of the vendored sources. The v2 expression
# carries exactly one `cargoHash`, and this refuses to guess once that stops
# being true, so a second Rust package can never cause the wrong hash to be
# rewritten.
set_vendor_hash() {
  local new=$1 lines
  mapfile -t lines < <(grep -n '^[[:space:]]*cargoHash[[:space:]]*=' "$PKG" | cut -d: -f1)
  [ "${#lines[@]}" -eq 1 ] || return 1
  sed -i "${lines[0]}s|^[[:space:]]*cargoHash[[:space:]]*=.*|  cargoHash = \"${new}\";|" "$PKG"
}

# The `cargoHash` currently in nix/package.nix. A reported mismatch is adopted
# only when it names this hash as `specified`, so a second fixed-output
# derivation (a fetchurl, another Rust package) can never have its hash written
# into `cargoHash`.
current_vendor_hash() {
  local line count
  count=$(grep -c '^[[:space:]]*cargoHash[[:space:]]*=' "$PKG") || count=0
  [ "$count" -eq 1 ] || return 1
  line=$(grep -m1 '^[[:space:]]*cargoHash[[:space:]]*=' "$PKG") || return 1
  printf '%s\n' "$line" | grep -oE 'sha256-[A-Za-z0-9+/=]+'
}

pin_url=$(current_pin_url) || die "could not evaluate flake.nix to read the nyaterm-src url"
[ -n "$pin_url" ] || die "nyaterm-src has no url in flake.nix"
pin=${pin_url#"github:"}
case "$pin" in
  "${UPSTREAM_SLUG}/"*) pin=${pin#"${UPSTREAM_SLUG}/"} ;;
  *) die "unrecognized nyaterm-src pin: ${pin_url}" ;;
esac

pin_from_commit=0
case "$pin" in
  v[0-9]*.[0-9]*.[0-9]*)
    [[ $pin =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
      die "nyaterm-src pins '${pin}', which is not a stable vX.Y.Z release tag"
    ;;
  *)
    # Only a full 40-character SHA is an immutable revision here. A shorter hex
    # string would be read as a branch or tag name, so accepting one would let
    # the commit path below hide a pin that cannot resolve.
    [[ $pin =~ ^[0-9a-f]{40}$ ]] ||
      die "nyaterm-src pins '${pin}', which is neither a stable vX.Y.Z release tag nor a full commit SHA"
    pin_from_commit=1
    # Everything below may rewrite the pin; the history check needs the commit
    # this run started from, not whatever the url becomes.
    PIN_COMMIT=$pin
    ;;
esac

major_of() {
  local tag=$1
  tag=${tag#v}
  printf '%s\n' "${tag%%.*}"
}

# The url this run started from. A commit pin is replaced by the tag its release
# carries, so the rewrite below has to recognize the original commit as ours.
ORIGINAL_URL=$pin_url
# The tag that a commit pin was normalized onto. It is the same source, so the url
# is rewritten onto it even when no other release is involved.
RELEASE_CLAIM=""
# The release line a pin belongs to. A tag names it; a commit pin has no version
# of its own, so it is the line the package was written for (v2). Upstream tags a
# squashed release commit rather than a commit on `main`, which is why a pending
# commit never becomes a tag target.
PIN_MAJOR=2
target=""

if [ "$pin_from_commit" -eq 0 ]; then
  major=$(major_of "$pin")
  # A pin on another line than this expression was written for is refused rather
  # than silently repackaged as a different major version.
  [ "$major" = "$PIN_MAJOR" ] ||
    die "nyaterm-src pins ${pin}, but ${FLAKE##*/} packages the v${PIN_MAJOR} line"
  log "pinned release: ${pin} (tracking the v${major} line)"
else
  major=$PIN_MAJOR
  # `git ls-remote` without `--refs` also lists the peeled commit of annotated
  # tags, which is what makes a commit pin matchable against a release.
  log "flake.nix pins a commit instead of a release tag: ${pin}"
  TAG_REFS=$(git ls-remote "$UPSTREAM_URL" 2>/dev/null) || die "failed to query upstream tags"
  # Anchored after the patch number, and the peeled suffix only after it, so a
  # pre-release such as `v2.1.0-rc1` can never masquerade as a stable tag.
  line_tags=$(printf '%s\n' "$TAG_REFS" |
    awk -v prefix="v${major}." '
      NF == 2 && $2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+(\^\{\})?$/ {
        tag = $2
        sub("^refs/tags/", "", tag)
        sub(/\^[{][}]$/, "", tag)
        if (!(tag in seen) && index(tag, prefix) == 1) print tag
        seen[tag] = 1
      }
    ')
  # Only this line's releases may enter the decision: following another major
  # line would silently repackage the app.
  [ -n "$line_tags" ] || die "no stable v${major}.x.y release tags found upstream"
  # A plain loop around a here-string, not a `cmd | while` pipeline: every
  # command in a pipeline runs in a subshell that inherits the EXIT trap, so a
  # pipeline here would delete the build log on return.
  exact=""
  while read -r tag; do
    [ -n "$tag" ] || continue
    [ "$(tag_commit "$tag")" = "$pin" ] || continue
    # Several tags can point at one commit; keep the highest, not the first.
    if [ -z "$exact" ] || [ "$(printf '%s\n%s\n' "$exact" "$tag" | sort -V | tail -1)" = "$tag" ]; then
      exact=$tag
    fi
  done <<<"$line_tags"
  if [ -n "$exact" ]; then
    # The same source under a release name, so the decision below still runs: it
    # rewrites the url when the tag is already newest and advances to a newer
    # release in the same run.
    log "the pinned commit already carries release ${exact}; the pin normalizes to that tag"
    pin=$exact
    RELEASE_CLAIM=$exact
  else
    # Upstream squashes a release before tagging it, so a commit no tag points at
    # is either not released yet or was rewritten by a force push. Only the
    # former may stay a pin. The probe runs in a scratch repository so the
    # caller's working directory never receives the object or a FETCH_HEAD.
    SCRATCH_DIR=$(mktemp -d)
    ok=1
    git -C "$SCRATCH_DIR" init --quiet || ok=0
    git -C "$SCRATCH_DIR" fetch --quiet --no-tags --depth=1 "$UPSTREAM_URL" "$pin" 2>/dev/null || ok=0
    rm -rf "$SCRATCH_DIR"
    SCRATCH_DIR=""
    [ "$ok" -eq 1 ] || die "upstream no longer serves the pinned commit ${pin}"
    log "the pin carries no version of its own; tracking the v${major} line"
  fi
fi

log "querying stable v${major}.x.y release tags at ${UPSTREAM_SLUG}"
latest=$(latest_stable "$major") || die "failed to query upstream release tags"
[ -n "$latest" ] || die "no stable v${major}.x.y release tags found upstream"
log "latest stable release on the v${major} line: ${latest}"

# A tag pin is compared by version. A commit pin has no version: it moves to the
# newest release of the line only when history shows that release carries it,
# which is asked of a scratch clone of upstream.

if [ "$pin_from_commit" -eq 1 ] && [ "$latest" != "${RELEASE_CLAIM:-$pin}" ]; then
  # A commit pin has no version, so it is never compared with releases. Every tag
  # check above used the newest tag of this line, which means `latest` is that tag
  # unless a release landed while the tags were being read; the question left is
  # whether that release actually carries the pinned commit. Upstream squashes a
  # release before tagging, so following a tag that predates the commit would
  # silently revert what the pin exists for. A failure to look is fatal: an
  # unanswerable question must never turn into a green run that quietly stops
  # updating. A commit that a release tag points at is no exception: that tag
  # normalizes the url, but moving past it to a newer release is still a move.
  newest=$(printf '%s\n' "$line_tags" | sort -V | tail -1)
  [ "$newest" = "$latest" ] ||
    log "release ${latest} landed while the tags were being read"
  log "checking whether ${latest} carries the pinned commit"
  # The packaging checkout only knows what it has fetched (CI clones it shallow)
  # and may even be a tarball export, so the question is asked of a scratch clone
  # of upstream. Both sides are fetched into explicit refs, because `--no-tags`
  # would otherwise only leave them in FETCH_HEAD. Upstream truncates a release
  # deliberately, which drops the commit from the tag's history, so this is the
  # pair that matters: the last release the pin can be tied to is the one a
  # normalizing run writes, and from there the comparison is tag to tag.
  SCRATCH_DIR=$(mktemp -d)
  git -C "$SCRATCH_DIR" init --quiet || die "could not create a scratch repository for the history check"
  git -C "$SCRATCH_DIR" fetch --quiet --no-tags "$UPSTREAM_URL" \
    "+refs/tags/${latest}:refs/tags/${latest}" \
    "${PIN_COMMIT}:refs/heads/pin" ||
    die "could not fetch ${PIN_COMMIT} and ${latest} for the history check"
  status=0
  git -C "$SCRATCH_DIR" merge-base --is-ancestor refs/heads/pin "refs/tags/${latest}" || status=$?
  rm -rf "$SCRATCH_DIR"
  SCRATCH_DIR=""
  case "$status" in
    0)
      log "${latest} contains the pinned commit; moving the pin to that release"
      target=$latest
      ;;
     1)
      if [ -n "$RELEASE_CLAIM" ]; then
        # The release that carries the commit is the normalization target; a
        # newer release that does not contain it must not replace it.
        log "${latest} does not contain the pinned commit, so the pin stops at ${RELEASE_CLAIM}"
        target=$RELEASE_CLAIM
      else
        log "${latest} does not contain the pinned commit, so the commit pin stays"
        log "move the pin by hand once a release that carries it is published"
      fi
      ;;
    *)
      die "could not determine whether ${latest} contains the pinned commit"
      ;;
  esac
elif [ "$latest" = "$pin" ]; then
  if [ -n "$RELEASE_CLAIM" ]; then
    # The tag that carries the pinned commit is the newest release: the same
    # source under its release name, so the url is rewritten onto it.
    target=$pin
  fi
  log "${pin} is already the newest stable release"
elif [ "$(printf '%s\n%s\n' "$pin" "$latest" | sort -V | tail -1)" = "$pin" ]; then
  if [ -n "$RELEASE_CLAIM" ]; then
    # The pin is already ahead of every other release, so the tag that carries it
    # is both the normalization target and the newest source available.
    target=$pin
  fi
  log "${pin} is ahead of upstream's newest stable release (${latest}); keeping the pin"
else
  log "bumping ${pin} -> ${latest}"
  target=$latest
fi

if [ -n "$target" ]; then
  # Validate against the live file in the same breath as the edit, so a line
  # inserted or removed since the run started cannot send sed at another url.
  current=$(current_pin_url) || die "could not re-read the nyaterm-src url from flake.nix"
  [ "$current" = "$ORIGINAL_URL" ] ||
    die "flake.nix pins ${current}, not ${ORIGINAL_URL}; refusing to rewrite it"
  line=$(pin_url_line)
  [ -n "$line" ] || die "could not locate the url line of the nyaterm-src input in flake.nix"
  case "$(sed -n "${line}p" "$FLAKE")" in
    *"${ORIGINAL_URL}"*) ;;
    *) die "flake.nix:${line} no longer holds ${ORIGINAL_URL}; refusing to rewrite it" ;;
  esac
  sed -i "${line}s|github:${UPSTREAM_SLUG}/[^\"]*|github:${UPSTREAM_SLUG}/${target}|" "$FLAKE"
  [ "$(current_pin_url)" = "github:${UPSTREAM_SLUG}/${target}" ] ||
    die "failed to rewrite the nyaterm-src pin in flake.nix"
  pin=$target
  DID_UPDATE=1
fi

log "refreshing flake.lock"
lock_before=$(git -C "$ROOT" hash-object "$ROOT/flake.lock")
(cd "$ROOT" && nix flake update nyaterm-src >/dev/null)
lock_after=$(git -C "$ROOT" hash-object "$ROOT/flake.lock")
[ "$lock_before" = "$lock_after" ] || DID_UPDATE=1

# Build, adopting each hash Nix reports until the build is clean. Fails loudly on
# any other build error so a genuine break is never papered over. The lock file is
# this script's own product (`nix flake update` above), so `--no-update-lock-file`
# turns a lock it failed to refresh into an error instead of letting Nix re-lock
# behind its back and build a revision the script never wrote.
built=0
for round in $(seq 1 "$MAX_HASH_ROUNDS"); do
  log "building ${BUILD_TARGET} (attempt ${round}/${MAX_HASH_ROUNDS})"
  if (cd "$ROOT" && nix build "$BUILD_TARGET" --no-update-lock-file -L) >"$LOG" 2>&1; then
    built=1
    break
  fi

  got=$(grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' "$LOG" | head -1 | awk '{print $2}') || got=""
  if [ -z "$got" ]; then
    cat "$LOG" >&2
    die "build failed for a reason other than a fixed-output hash mismatch"
  fi

  specified=$(grep -oE 'specified:[[:space:]]+sha256-[A-Za-z0-9+/=]+' "$LOG" | head -1 | awk '{print $2}') || specified=""
  # Only the vendored-sources FOD may be adopted: if the failing derivation's
  # specified hash is not the cargoHash in nix/package.nix, something else broke
  # and rewriting cargoHash would corrupt the expression.
  current=$(current_vendor_hash) || die "cannot read the current cargoHash from nix/package.nix"
  [ "$specified" = "$current" ] ||
    die "the failing fixed-output derivation is not the cargoHash FOD (specified: ${specified:-<none>}, cargoHash: ${current}); refusing to adopt its hash"
  log "hash mismatch (${specified} -> ${got}); updating nix/package.nix"
  set_vendor_hash "$got" || die "cannot map the reported hash onto a source in nix/package.nix"
  DID_UPDATE=1
done

[ "$built" -eq 1 ] || die "gave up after ${MAX_HASH_ROUNDS} hash rounds"

if [ "${UPDATE_UPSTREAM_SKIP_VERIFY:-0}" != "1" ]; then
  log "verifying package outputs"
  system=$(nix eval --impure --raw --expr builtins.currentSystem) \
    || die "could not determine the current system"
  (cd "$ROOT" && nix build --no-link --no-update-lock-file ".#checks.${system}.nyaterm" -L) \
    || die "package outputs failed verification"
fi

log "build OK, package outputs verified"

if [ "$DO_COMMIT" -eq 1 ]; then
  if [ -n "$(git -C "$ROOT" status --porcelain -- "${COMMIT_PATHS[@]}")" ]; then
    log "committing"
    git -C "$ROOT" add "${COMMIT_PATHS[@]}"
    git -C "$ROOT" commit -q -m "chore(nix): update NyaTerm to ${pin##*/}"
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
