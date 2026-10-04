#!/usr/bin/env bash
# Step 9 - BigQuery ledger (GCP). The GOVERNED reconciliation agent reads the ledger from BigQuery
# (GCP) through the fabric-bigquery Gateway connector, while the policy SOP stays in the Bedrock KB
# (AWS) through the fabric-knowledge connector - so one duplicate-charge case spans AWS + GCP, all via
# the one AgentCore Gateway. A faithful copy of DynamoDB bank-ledger (same transactions; the direct
# variant still reads the DynamoDB copy). Read-only demo data in the existing fabric GCP project.
#
# Needs gcloud/bq authed on the fabric GCP project. Idempotent: recreates the table each run.
set -euo pipefail
. "$(dirname "$0")/config.sh"
export PATH="$PATH:/home/ubuntu/google-cloud-sdk/bin"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

GCP_PROJECT="${FABRIC_GCP_PROJECT:-test-xyz-12345}"
DATASET="bank_ledger"
TABLE="transactions"
FQT="${GCP_PROJECT}:${DATASET}.${TABLE}"

echo "mirroring DynamoDB $LEDGER_TABLE -> BigQuery ${FQT} (faithful ledger copy)"

# ---- flatten the operational ledger to BigQuery rows (faithful - no discrepancies; it IS the ledger) ----
NDJSON="$(mktemp /tmp/bank_ledger.XXXXXX.ndjson)"
LEDGER_TABLE="$LEDGER_TABLE" REGION="$REGION" python3 - "$NDJSON" <<'PY'
import boto3, json, sys, os
out = open(sys.argv[1], "w")
ddb = boto3.resource("dynamodb", region_name=os.environ["REGION"]).Table(os.environ["LEDGER_TABLE"])
n = 0
for i in ddb.scan().get("Items", []):
    cust = i.get("customer", {}) or {}
    out.write(json.dumps({
        "account_id": i["account_id"], "txn_id": i["txn_id"], "amount": float(i["amount"]),
        "ts": i.get("ts", ""), "merchant": i.get("merchant", ""),
        "customer_name": cust.get("name", ""), "customer_pan": cust.get("pan", ""),
        "fraud_risk_score": float(i["fraud_risk_score"]) if i.get("fraud_risk_score") is not None else None,
    }) + "\n"); n += 1
out.close()
print(f"  {n} ledger rows", file=sys.stderr)
PY

# ---- (re)create dataset + table, grant the fabric-bigquery connector SA READ, load ----
bq --project_id="$GCP_PROJECT" mk --force --dataset \
  --description "Bank operational ledger (GCP copy, read via the fabric Gateway) - demo" "${GCP_PROJECT}:${DATASET}" 2>/dev/null || true

BQ_SA="fabric-bq@${GCP_PROJECT}.iam.gserviceaccount.com"
ACL_TMP="$(mktemp)"
bq --project_id="$GCP_PROJECT" show --format=prettyjson "${GCP_PROJECT}:${DATASET}" > "$ACL_TMP"
BQ_SA="$BQ_SA" python3 - "$ACL_TMP" <<'PY'
import json, os, sys
f, sa = sys.argv[1], os.environ["BQ_SA"]
d = json.load(open(f)); acc = d.get("access", [])
if not any(e.get("userByEmail") == sa and e.get("role") in ("READER", "roles/bigquery.dataViewer") for e in acc):
    acc.append({"role": "READER", "userByEmail": sa}); d["access"] = acc
    json.dump(d, open(f, "w")); print("  dataset READER granted to", sa)
else:
    print("  dataset READER already granted to", sa)
PY
bq --project_id="$GCP_PROJECT" update --source "$ACL_TMP" "${GCP_PROJECT}:${DATASET}" >/dev/null && rm -f "$ACL_TMP"

bq --project_id="$GCP_PROJECT" rm -f -t "$FQT" 2>/dev/null || true
bq --project_id="$GCP_PROJECT" load --source_format=NEWLINE_DELIMITED_JSON --replace "$FQT" "$NDJSON" \
  "account_id:STRING,txn_id:STRING,amount:FLOAT,ts:STRING,merchant:STRING,customer_name:STRING,customer_pan:STRING,fraud_risk_score:FLOAT"
rm -f "$NDJSON"

# ---- drop the superseded reconciliation-era warehouse dataset, if present ----
bq --project_id="$GCP_PROJECT" rm -r -f -d "${GCP_PROJECT}:bank_warehouse" 2>/dev/null && echo "removed superseded bank_warehouse dataset" || true

echo "ledger ready in BigQuery: ${FQT}"
