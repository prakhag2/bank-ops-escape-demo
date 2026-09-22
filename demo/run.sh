#!/usr/bin/env bash
# Launch the live demo viewer. Reads the runtime ARNs from infra/state.env and serves the UI + API.
set -euo pipefail
cd "$(dirname "$0")"                 # demo/ — so `import annotate` (a sibling) resolves
set -a; . ../infra/state.env; set +a
PORT="${PORT:-8080}"
echo "demo viewer on http://localhost:${PORT}  (Ctrl-C to stop)"
exec python3 -m uvicorn server:app --host 0.0.0.0 --port "${PORT}"
