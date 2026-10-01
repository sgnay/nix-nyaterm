#!/usr/bin/env bash
# Verify a built package contains everything NyaTerm needs at runtime.
# Shared by nix.yml and update.yml so both check the same things.
set -euo pipefail

result=${1:-result}

for f in \
  bin/nyaterm \
  bin/nyaterm-mcp \
  share/applications/nyaterm.desktop \
  share/icons/hicolor/32x32/apps/nyaterm.png \
  share/icons/hicolor/128x128/apps/nyaterm.png \
  share/icons/hicolor/256x256/apps/nyaterm.png; do
  [ -e "${result}/${f}" ] || {
    printf 'error: expected output missing: %s/%s\n' "$result" "$f" >&2
    exit 1
  }
done

# The frontend must be embedded in the binary, not read from a source tree.
if ! grep -rqa -- '/assets/' "${result}/bin"; then
  printf 'error: frontend assets are not embedded in %s/bin\n' "$result" >&2
  exit 1
fi

printf 'All required package outputs verified in %s.\n' "$result"