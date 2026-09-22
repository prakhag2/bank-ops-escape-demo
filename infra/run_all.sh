#!/usr/bin/env bash
# Stand up the whole bank-demo platform, in order. Idempotent — safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
source ../venv/bin/activate 2>/dev/null || source venv/bin/activate

for s in 01_kms 02_dynamodb 03_s3 04_iam 05_vectors 06_bedrock_kb; do
  echo "=== infra/$s.sh ==="
  bash "infra/$s.sh"
done
echo "=== infra/seed.py ==="
python infra/seed.py
for s in 07_network 08_runtime; do
  echo "=== infra/$s.sh ==="
  bash "infra/$s.sh"
done
echo "=== platform up ==="
