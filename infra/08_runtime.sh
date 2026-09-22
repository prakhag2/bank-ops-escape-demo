#!/usr/bin/env bash
# Deploy the two agents as AgentCore runtimes, each under its own execution role, both pinned to the
# sealed agent subnets. Reconciliation is deployed first so the orchestrator can be told its ARN.
# Inbound auth is SigV4 (IAM): a caller needs bedrock-agentcore:InvokeAgentRuntime, so the boundary
# also lives at the invoke edge.
source "$(dirname "$0")/config.sh"
source "$STATE_FILE"
cd "$(dirname "$0")/.."
source ../venv/bin/activate 2>/dev/null || source venv/bin/activate
KB_ID=$(grep -E '^KB_ID=' "$STATE_FILE" | cut -d= -f2)

# --- Code-deploy bucket (holds the zipped source AgentCore pulls; private, encrypted, TLS-only) ---
if ! aws s3api head-bucket --bucket "$DEPLOY_BUCKET" >/dev/null 2>&1; then
  aws s3api create-bucket --bucket "$DEPLOY_BUCKET" >/dev/null
  echo "created deploy bucket $DEPLOY_BUCKET"
fi
aws s3api put-public-access-block --bucket "$DEPLOY_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$DEPLOY_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$DEPLOY_BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-policy --bucket "$DEPLOY_BUCKET" --policy "{
  \"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"DenyInsecureTransport\",\"Effect\":\"Deny\",
  \"Principal\":\"*\",\"Action\":\"s3:*\",
  \"Resource\":[\"arn:aws:s3:::$DEPLOY_BUCKET\",\"arn:aws:s3:::$DEPLOY_BUCKET/*\"],
  \"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}"

runtime_arn () {  # name -> its runtime ARN (empty if not yet created)
  aws bedrock-agentcore-control list-agent-runtimes \
    --query "agentRuntimes[?agentRuntimeName=='$1'].agentRuntimeArn | [0]" --output text 2>/dev/null
}

# Package only the runtime code. Staging excludes infra/ (provisioning scripts + state.env) so the
# deployed agent never receives the network topology and must discover any egress path on its own.
ROOT=$(pwd)
PKG=$(mktemp -d)
cp "$ROOT"/*.py "$ROOT"/requirements.txt "$PKG"/
cd "$PKG"

# --- Reconciliation runtime (sealed subnets, its own broad-read identity) ---
agentcore configure -e runtime_reconciliation.py -n "$RECON_RUNTIME_NAME" \
  -er "$RECON_ROLE_ARN" -s3 "$DEPLOY_BUCKET" -rf requirements.txt \
  -dt direct_code_deploy --vpc --subnets "$AGENT_SUBNET_A,$AGENT_SUBNET_B" \
  --security-groups "$AGENT_SG" -dm -do -r "$REGION" -ni
agentcore launch -a "$RECON_RUNTIME_NAME" --auto-update-on-conflict --env "KB_ID=$KB_ID"
RECON_RUNTIME_ARN=$(runtime_arn "$RECON_RUNTIME_NAME")
echo "reconciliation runtime: $RECON_RUNTIME_ARN"

# --- Orchestrator runtime (sealed subnets, customer-scoped identity; told the recon ARN + KB) ---
agentcore configure -e runtime_orchestrator.py -n "$ORCH_RUNTIME_NAME" \
  -er "$ORCH_ROLE_ARN" -s3 "$DEPLOY_BUCKET" -rf requirements.txt \
  -dt direct_code_deploy --vpc --subnets "$AGENT_SUBNET_A,$AGENT_SUBNET_B" \
  --security-groups "$AGENT_SG" -dm -do -r "$REGION" -ni
agentcore launch -a "$ORCH_RUNTIME_NAME" --auto-update-on-conflict \
  --env "RECON_RUNTIME_ARN=$RECON_RUNTIME_ARN" --env "KB_ID=$KB_ID"
ORCH_RUNTIME_ARN=$(runtime_arn "$ORCH_RUNTIME_NAME")
echo "orchestrator runtime: $ORCH_RUNTIME_ARN"

cd "$ROOT"
rm -rf "$PKG"

# Orchestrator may invoke ONLY the reconciliation runtime (exact ARN, known only now).
T=$(mktemp -d)
cat > "$T/invoke.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"InvokeRecon","Effect":"Allow",
 "Action":["bedrock-agentcore:InvokeAgentRuntime"],
 "Resource":["$RECON_RUNTIME_ARN","$RECON_RUNTIME_ARN/*"]}]}
JSON
aws iam put-role-policy --role-name "$ORCH_ROLE" --policy-name invoke-recon --policy-document "file://$T/invoke.json"
rm -rf "$T"
echo "granted $ORCH_ROLE InvokeAgentRuntime on reconciliation runtime"

{ echo "ORCH_RUNTIME_ARN=$ORCH_RUNTIME_ARN"; echo "RECON_RUNTIME_ARN=$RECON_RUNTIME_ARN"; } > "$STATE_FILE.tmp"
grep -v -E '^(ORCH_RUNTIME_ARN|RECON_RUNTIME_ARN)=' "$STATE_FILE" 2>/dev/null >> "$STATE_FILE.tmp" || true
mv "$STATE_FILE.tmp" "$STATE_FILE"
echo "runtimes deployed"
