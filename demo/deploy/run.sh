#!/usr/bin/env bash
# Serve the DEPLOYED demo (behind CloudFront): the edge gate enforces the origin secret.
# Run this after provision_cloudfront.py up. For local dev use demo/run.sh instead.
set -euo pipefail
cd "$(dirname "$0")/.."                      # demo/ — so edge_gate can import server
set -a; . ../infra/state.env; . deploy/.env; set +a   # runtime ARNs + origin secret / creds
PORT="${PORT:-8080}"
echo "edge-gated demo on :${PORT} (origin secret enforced; reach it via the CloudFront URL)"
exec python3 -m uvicorn deploy.edge_gate:app --host 0.0.0.0 --port "${PORT}"
