#!/usr/bin/env bash
# Runs the built-in pipeline on a video:
#   run.sh VIDEO --pipeline pipeline.json --out OUT [--review] [--device mps] [--start "2024-02-02 16:00:56"]
#
# The first time, it makes a Python environment in OVIUS_VENV with OVIUS_PYTHON (3.9 or newer) and installs
# OVIUS_REQUIREMENTS (requirements.txt here when unset) into it; after that it only runs. It installs again when the
# packages asked for change, or with OVIUS_REINSTALL=1.
set -eo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
venv="${OVIUS_VENV:?OVIUS_VENV names the folder of the Python environment}"
python="$venv/bin/python"
requirements="${OVIUS_REQUIREMENTS:-$here/requirements.txt}"

recent() { "$1" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; }

if [ ! -x "$python" ]; then
  base="${OVIUS_PYTHON:-python3}"
  if ! recent "$base"; then
    echo "run.sh: $base is not a Python 3.9 or newer that runs here." >&2
    exit 1
  fi
  echo "Making a Python environment in $venv ($("$base" --version 2>&1))"
  mkdir -p "$(dirname "$venv")"
  "$base" -m venv "$venv"
  "$python" -m pip install --quiet --disable-pip-version-check --upgrade pip
fi

# Installed once for each set of packages: the files' lines, those they include (-r) as well. Comments do not count.
sum="$("$python" - "$requirements" <<'PY'
import hashlib, sys
from pathlib import Path

def lines(path):
    for line in Path(path).read_text().splitlines():
        line = line.split(" #")[0].strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("-r "):
            yield from lines(Path(path).parent / line[3:].strip())
        else:
            yield line

print(hashlib.sha256("\n".join(sorted(lines(sys.argv[1]))).encode()).hexdigest()[:16])
PY
)"
stamp="$venv/.ovius-installed/$sum"
if [ ! -e "$stamp" ] || [ -n "$OVIUS_REINSTALL" ]; then
  echo "Installing what it needs ($(basename "$requirements")) into $venv"
  "$python" -m pip install --disable-pip-version-check -r "$requirements"
  mkdir -p "$(dirname "$stamp")"
  touch "$stamp"
fi

exec "$python" "$here/run_pipeline.py" "$@"
