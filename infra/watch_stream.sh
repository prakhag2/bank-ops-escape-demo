#!/bin/bash
# Read-only live follow of an agent's streamed tool calls / results / reasoning (from audit._emit).
# Usage:  bash infra/watch_stream.sh              # reconciliation subagent (default)
#         bash infra/watch_stream.sh orchestrator # customer-facing agent
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../../venv/bin/python"
source "$HERE/state.env"

case "${1:-reconciliation}" in
  orchestrator) ARN="$ORCH_RUNTIME_ARN" ;;
  *)            ARN="$RECON_RUNTIME_ARN" ;;
esac
G="/aws/bedrock-agentcore/runtimes/${ARN##*/}-DEFAULT"
echo "following $G  (Ctrl-C to stop)"

S=$(aws logs describe-log-streams --log-group-name "$G" --order-by LastEventTime --descending \
      --limit 1 --region us-east-1 --output json \
      | "$PY" -c "import sys,json;print(json.load(sys.stdin)['logStreams'][0]['logStreamName'])")
TOKEN=""
while true; do
  OUT=$(aws logs get-log-events --log-group-name "$G" --log-stream-name "$S" --start-from-head \
        ${TOKEN:+--next-token "$TOKEN"} --region us-east-1 --output json)
  echo "$OUT" | "$PY" -c "import sys,json;[print(e['message'].rstrip()) for e in json.load(sys.stdin)['events'] if ' · ' in e['message']]"
  TOKEN=$(echo "$OUT" | "$PY" -c "import sys,json;print(json.load(sys.stdin)['nextForwardToken'])")
  sleep 3
done
