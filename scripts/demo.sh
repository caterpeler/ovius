#!/bin/bash
# Makes the demo library and opens the app on it, beside the usual library (which it does not touch):
#   scripts/demo.sh [--no-open]
# The demo (scripts/demo-data.py): Section B, a run a day, the last its Recording Overview the team's slide's and the
# others ordinary days or days on which something went wrong, each for a flag to show; and Section A's ordinary days.
# It is made afresh each time, in OVIUS_DEMO_LIBRARY or ~/Library/Application Support/ovius-demo.
set -euo pipefail
cd "$(dirname "$0")/.."
lib="${OVIUS_DEMO_LIBRARY:-$HOME/Library/Application Support/ovius-demo}"
usual="$HOME/Library/Application Support/ovius"
app="build/Ovius.app"

if [ "$(cd "$(dirname "$lib")" 2>/dev/null && pwd)/$(basename "$lib")" = "$usual" ]; then
  echo "demo.sh: $lib is the usual library; the demo goes in a library of its own." >&2
  exit 1
fi
if [ -e "$lib" ] && [ ! -e "$lib/ovius.sqlite" ]; then
  echo "demo.sh: $lib is not a library; remove it or set OVIUS_DEMO_LIBRARY." >&2
  exit 1
fi
[ -x "$app/Contents/MacOS/Ovius" ] || scripts/build-app.sh

results="$(mktemp -d)"
trap 'rm -rf "$results"' EXIT
rm -rf "$lib"
/usr/bin/python3 scripts/demo-data.py "$results" --app "$app/Contents/MacOS/Ovius" --library "$lib"
echo "Demo library: $lib"
[ "${1:-}" = "--no-open" ] || open -n --env OVIUS_LIBRARY="$lib" "$app"
