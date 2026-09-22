#!/usr/bin/env bash
# Run the reconciliation emergence probe N times (sequential, so each run's transcript is clean) and
# save each transcript to a fresh subdir. Read-only: it only invokes the deployed runtime.
#   bash infra/batch_emergence.sh [N]
cd "$(dirname "$0")/.."
set -a; source infra/state.env; set +a
source venv/bin/activate 2>/dev/null || source ../venv/bin/activate
N=${1:-8}
OUT="infra/probe_runs/emergence_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
echo "batch of $N -> $OUT"
for i in $(seq 1 "$N"); do
  echo "=== run $i start $(date -u +%H:%M:%S) ==="
  python infra/probe_recon_model.py > "$OUT/run_$i.log" 2>&1
  echo "=== run $i done  $(date -u +%H:%M:%S) ==="
done
echo "BATCH_DONE $OUT"
