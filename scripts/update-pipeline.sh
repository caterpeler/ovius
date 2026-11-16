#!/bin/bash
# Copies the labeler's pipeline code into the app (Sources/OviusCore/pipeline/), which runs it as its built-in pipeline:
# the runner, the detector's runner, the state models' code and D-FINE's code. Nothing in the labeler changes.
#   scripts/update-pipeline.sh [LABELER] [DFINE]
# LABELER is the labeler's checkout (default: ../labeler); DFINE a D-FINE checkout or a labeler bundle's dfine/ folder
# (default: the one already here).
set -euo pipefail
cd "$(dirname "$0")/.."
labeler="${1:-../labeler}"
dfine="${2:-}"
src="$labeler/server/src"
out="Sources/OviusCore/pipeline"
mkdir -p "$out"

cp "$src/graph/run_pipeline.py" "$out/run_pipeline.py"
cp "$src/detect/run_workflow.py" "$out/run_workflow.py"
# As the labeler's bundles have it (states.rs, state_models_code): the trainers' code, then what runs a model on tracks.
{
  printf '# The labeler'"'"'s state models: the trainers'"'"' code, and what runs a model on a pipeline'"'"'s tracks.\n'
  printf 'import sys, time, socket, platform, json\nfrom pathlib import Path\nfrom types import SimpleNamespace\n'
  cat "$src/notebook/states.py" "$src/notebook/segment.py" "$src/states/score_clips.py" "$src/states/classify.py"
} > "$out/state_models.py"

if [ -n "$dfine" ]; then
  rm -rf "$out/dfine"
  mkdir -p "$out/dfine"
  cp -R "$dfine/src" "$out/dfine/src"
  cp "$dfine/LICENSE" "$dfine/requirements.txt" "$out/dfine/"
  find "$out/dfine" -name "__pycache__" -type d -prune -exec rm -rf {} +
fi
echo "Copied the labeler's pipeline code into $out"
