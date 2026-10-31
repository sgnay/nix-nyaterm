#!/usr/bin/env bash
# Regression tests for the pin handling in scripts/update-upstream.sh.
#
# Every case builds a throwaway Git repository that plays the packaging checkout,
# stub `git`/`nix` binaries that answer the way upstream would, and then runs the
# real script against them. Nothing here needs network access, a Nix store, or a
# package build, so the decision logic stays covered on every change.
#
# Usage: scripts/tests/update-upstream-test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="${ROOT}/scripts/update-upstream.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CASE=""

pass() {
  PASS=$((PASS + 1))
  printf 'ok   %s\n' "$CASE"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$CASE"
  printf '     %s\n' "$*"
}

# A fresh packaging checkout with a stub answering the way upstream would.
# Args: the pin in flake.nix, the `git ls-remote` output, the `--refs` output
setup() {
  local pin=$1 refs=$2 tags=$3
  CASE_DIR="${WORK}/case${PASS}${FAIL}"
  mkdir -p "${CASE_DIR}/bin"
  cat >"${CASE_DIR}/flake.nix" <<EOF
{
  outputs = { nyaterm-src, ... }: {
    nyaterm-src = {
      url = "github:nyakang/nyaterm/${pin}";
      flake = false;
    };
  };
}
EOF
  cat >"${CASE_DIR}/package.nix" <<'EOF'
{
  cargoHash = "sha256-CURRENT000000000000000000000000000000000000=";
}
EOF
  printf '%s\n' "$refs" >"${CASE_DIR}/refs.txt"
  printf '%s\n' "$tags" >"${CASE_DIR}/tags.txt"
  # The build always succeeds, so a case can only fail on the pin logic.
  cat >"${CASE_DIR}/bin/nix" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  eval)
    # Two questions: the `nyaterm-src` url, and the current system.
    if printf '%s' "$*" | grep -qF -- 'nyaterm-src.url'; then
      # The url, without its scheme; the caller strips the repository part.
      sed -n 's/^[[:space:]]*url = "\(.*\)";.*/\1/p' "${CASE_DIR}/flake.nix"
    else
      printf 'x86_64-linux\n'
    fi
    ;;
  flake) ;;   # flake update: the lockfile is not inspected by these cases
  build) ;;   # the build and the output check always pass
  *) exit 1 ;;
esac
STUB
  sed -i -E 's|\$\{CASE_DIR\}|'"${CASE_DIR}"'|g' "${CASE_DIR}/bin/nix"
  cat >"${CASE_DIR}/bin/git" <<'STUB'
#!/usr/bin/env bash
# Answers the `ls-remote` and history-check questions the updater asks.
while [ $# -gt 0 ]; do
  case "$1" in
    -C|-c|--git-dir) shift 2 ;;
    *) break ;;
  esac
done
cmd=${1:-}
shift || true
case "$cmd" in
  ls-remote)
    for a in "$@"; do
      [ "$a" = --refs ] && tags_only=1
    done
    if [ "${tags_only:-0}" = 1 ]; then
      awk '$2 ~ /^refs\/tags\// { print }' "$CASE_DIR/tags.txt"
    else
      cat "$CASE_DIR/refs.txt"
    fi
    ;;
  init|fetch|hash-object) ;;
  merge-base) exit "$(cat "$CASE_DIR/merge_base_status" 2>/dev/null || echo 0)" ;;
  status) ;;   # nothing is modified: only the pin rewrite is under test
  *) exit 0 ;;
esac
STUB
  sed -i -E "s|\\\$CASE_DIR|${CASE_DIR}|g" "${CASE_DIR}/bin/git"
  chmod +x "${CASE_DIR}/bin/nix" "${CASE_DIR}/bin/git"
  mkdir -p "${CASE_DIR}/scripts"
  cp "$SCRIPT" "${CASE_DIR}/scripts/update-upstream.sh"
  chmod +x "${CASE_DIR}/scripts/update-upstream.sh"
}

# Run the script once more against the same checkout. A case that has already
# rewritten flake.nix uses this to see what the next weekly run does with it.
# Args: expected exit code, and text that must appear in the output.
run_again() {
  local want_exit=$1 want_text=$2
  local out
  out=$(cd "$CASE_DIR" && PATH="${CASE_DIR}/bin:$PATH" \
    UPDATE_UPSTREAM_SKIP_VERIFY=1 HOME="$CASE_DIR" \
    bash scripts/update-upstream.sh 2>&1)
  local status=$?
  if [ "$status" -ne "$want_exit" ]; then
    fail "exit ${status}, wanted ${want_exit}: ${out}"
    return
  fi
  if ! printf '%s' "$out" | grep -qF -- "$want_text"; then
    fail "output missing '${want_text}': ${out}"
    return
  fi
  pass
}

# Args: expected exit code, and text that must appear in the output.
run_case() {
  run_again "$1" "$2"
}

# Args: the pin now expected in flake.nix.
expect_pin() {
  local want=$1 got
  got=$(sed -n 's/^[[:space:]]*url = "github:nyakang\/nyaterm\/\(.*\)";.*/\1/p' \
    "${CASE_DIR}/flake.nix")
  if [ "$got" = "$want" ]; then
    pass
  else
    fail "flake.nix pins ${got}, wanted ${want}"
  fi
}

COMMIT=cc35a5f93a7f6f9b129aa98af07b0185c8b39468
OWNS_TAG=1a4491ba00000000000000000000000000000000
V2_0_0=v2.0.0

# The `refs/tags/v2.0.0` peeled entry is the commit that tag points at; the
# normalization case pins exactly that commit.
REF_REFS="1111111111111111111111111111111111111111	refs/heads/main
1a4491ba00000000000000000000000000000000	refs/tags/v2.0.0
1a4491ba00000000000000000000000000000000	refs/tags/v2.0.0^{}"
REF_TAGS='1a4491ba00000000000000000000000000000000	refs/tags/v2.0.0'

# A second line: v2.1.0 exists, and no tag points at the pinned commit.
DRIFT_TAGS='dddddddddddddddddddddddddddddddddddddddd	refs/tags/v2.0.0
dddddddddddddddddddddddddddddddddddddddd	refs/tags/v2.0.0^{}
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee	refs/tags/v2.1.0'

# A commit no tag points at, and no release contains: the pin has to stay.
CASE="pending commit is kept and the run stays green"
setup "$COMMIT" "$REF_REFS" "$REF_TAGS"
printf '1' >"$CASE_DIR/merge_base_status"
run_case 0 "does not contain the pinned commit, so the commit pin stays"
expect_pin "$COMMIT"

# A commit the release tag points at: same source, so the url becomes the tag.
CASE="a commit that owns a release tag is rewritten to that tag"
setup "$OWNS_TAG" "$REF_REFS" "$REF_TAGS"
printf '0' >"$CASE_DIR/merge_base_status"
run_case 0 "the pin normalizes to that tag"
expect_pin "$V2_0_0"
# A later run sees an ordinary tag pin and keeps following this line's releases.
run_again 0 "is already the newest stable release"
expect_pin "$V2_0_0"

# The same commit, with a newer release whose history does not contain it: the
# pin must still be written, but only as far as the release that carries it.
CASE="a newer release that does not contain the commit does not win over its tag"
setup "$OWNS_TAG" "$REF_REFS" "$DRIFT_TAGS"
printf '1' >"$CASE_DIR/merge_base_status"
run_case 0 "so the pin stops at v2.0.0"
expect_pin "$V2_0_0"
# The commit is gone from flake.nix now, so the next run can only compare tags
# and moves to v2.1.0. This records that limit rather than hiding it.
run_again 0 "bumping v2.0.0 -> v2.1.0"
expect_pin v2.1.0

# A release cut from a squashed commit, proven to contain the pinned one.
CASE="a release that contains the pinned commit becomes the new pin"
setup "$COMMIT" "$REF_REFS" "$DRIFT_TAGS"
printf '0' >"$CASE_DIR/merge_base_status"
run_case 0 "contains the pinned commit; moving the pin to that release"
expect_pin v2.1.0

# A failure to look must never look like "nothing to do".
CASE="a failing history check is fatal"
setup "$COMMIT" "$REF_REFS" "$REF_TAGS"
printf '128' >"$CASE_DIR/merge_base_status"
run_case 1 "could not determine whether v2.0.0 contains the pinned commit"

# Pin shapes the updater refuses to guess about.
CASE="a branch name is refused"
setup main "$REF_REFS" "$REF_TAGS"
run_case 1 "is neither a stable vX.Y.Z release tag nor a full commit SHA"

CASE="a short SHA is refused"
setup cc35a5f "$REF_REFS" "$REF_TAGS"
run_case 1 "is neither a stable vX.Y.Z release tag nor a full commit SHA"

CASE="a pre-release tag is refused"
setup v2.0.0-preview.3 "$REF_REFS" "$REF_TAGS"
run_case 1 "is not a stable vX.Y.Z release tag"

CASE="a pin on another major line is refused"
setup v1.3.2 "$REF_REFS" "$REF_TAGS"
run_case 1 "packages the v2 line"

# A tag pin behind the newest release is advanced.
CASE="a tag pin behind the newest release is bumped"
setup v2.0.0 "$REF_REFS" "$REF_TAGS"
mv "$CASE_DIR/tags.txt" "$CASE_DIR/tags.tmp"
sed 's/v2\.0\.0/v2.1.0/' "$CASE_DIR/tags.tmp" >"$CASE_DIR/tags.txt"
rm -f "$CASE_DIR/tags.tmp"
run_case 0 "bumping v2.0.0 -> v2.1.0"
expect_pin v2.1.0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
