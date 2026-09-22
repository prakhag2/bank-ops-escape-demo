#!/usr/bin/env bash
# The demo identities. The orchestrator and reconciliation roles are AgentCore execution roles —
# each IS an agent's identity. They are identical except for one line: the orchestrator's ledger
# access carries a dynamodb:LeadingKeys condition pinning it to the authenticated customer; the
# reconciliation role has no such condition. That single missing line is the authorization boundary.
source "$(dirname "$0")/config.sh"
KMS_KEY_ARN=$(aws kms describe-key --key-id "$KMS_ALIAS" --query KeyMetadata.Arn --output text)
ACC_ARN=arn:aws:dynamodb:${REGION}:${ACCOUNT}:table/${ACCOUNTS_TABLE}
LED_ARN=arn:aws:dynamodb:${REGION}:${ACCOUNT}:table/${LEDGER_TABLE}
BUCKET_ARN=arn:aws:s3:::${POLICY_BUCKET}
T=$(mktemp -d)

upsert_role () {  # name  trust-json-file
  aws iam get-role --role-name "$1" >/dev/null 2>&1 \
    && aws iam update-assume-role-policy --role-name "$1" --policy-document "file://$2" \
    || aws iam create-role --role-name "$1" --assume-role-policy-document "file://$2" \
         --tags Key=$TAG_KEY,Value=$TAG_VAL >/dev/null
}

delete_role () {  # name — remove inline policies then the role
  for p in $(aws iam list-role-policies --role-name "$1" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$1" --policy-name "$p" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$1" 2>/dev/null && echo "removed deprecated role $1" || true
}

# --- Knowledge-base service role (assumed by Bedrock) ---
cat > "$T/kb-trust.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"bedrock.amazonaws.com"},"Action":"sts:AssumeRole",
 "Condition":{"StringEquals":{"aws:SourceAccount":"$ACCOUNT"}}}]}
JSON
upsert_role "$KB_ROLE" "$T/kb-trust.json"
# Vector-store (s3vectors) access is attached in 05 with the exact bucket/index ARNs.
cat > "$T/kb-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"ReadPolicyDocs","Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],
  "Resource":["$BUCKET_ARN","$BUCKET_ARN/*"]},
 {"Sid":"Embed","Effect":"Allow","Action":"bedrock:InvokeModel","Resource":"$EMBED_MODEL_ARN"},
 {"Sid":"DecryptDocs","Effect":"Allow","Action":["kms:Decrypt","kms:GenerateDataKey","kms:DescribeKey"],
  "Resource":"$KMS_KEY_ARN","Condition":{"StringEquals":{"kms:ViaService":"s3.${REGION}.amazonaws.com"}}}
]}
JSON
aws iam put-role-policy --role-name "$KB_ROLE" --policy-name kb-access --policy-document "file://$T/kb-policy.json"
echo "role $KB_ROLE ready"

# --- AgentCore execution-role trust (shared by both agent identities) ---
cat > "$T/agentcore-trust.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"AssumeRolePolicy","Effect":"Allow",
 "Principal":{"Service":"bedrock-agentcore.amazonaws.com"},"Action":"sts:AssumeRole",
 "Condition":{"StringEquals":{"aws:SourceAccount":"$ACCOUNT"},
   "ArnLike":{"aws:SourceArn":"arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:*"}}}]}
JSON

# Shared AgentCore runtime baseline (logs, metrics, one model, workload identity). Prints JSON
# statements (comma-terminated) for the given inference profile + its foundation-model family.
baseline_stmts () {  # model-profile-arn  model-fm-arn
  cat <<JSON
 {"Sid":"Logs","Effect":"Allow","Action":["logs:DescribeLogStreams","logs:CreateLogGroup"],
  "Resource":["arn:aws:logs:${REGION}:${ACCOUNT}:log-group:/aws/bedrock-agentcore/runtimes/*"]},
 {"Sid":"LogsDescribe","Effect":"Allow","Action":["logs:DescribeLogGroups"],
  "Resource":["arn:aws:logs:${REGION}:${ACCOUNT}:log-group:*"]},
 {"Sid":"LogsStream","Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":["arn:aws:logs:${REGION}:${ACCOUNT}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"]},
 {"Sid":"LogsDelivery","Effect":"Allow","Action":["logs:CreateLogGroup","logs:PutDeliverySource",
   "logs:PutDeliveryDestination","logs:CreateDelivery","logs:GetDeliverySource",
   "logs:DeleteDeliverySource","logs:DeleteDeliveryDestination"],"Resource":"*"},
 {"Sid":"Xray","Effect":"Allow","Action":["xray:PutTraceSegments","xray:PutTelemetryRecords",
   "xray:GetSamplingRules","xray:GetSamplingTargets"],"Resource":["*"]},
 {"Sid":"Metrics","Effect":"Allow","Action":"cloudwatch:PutMetricData","Resource":"*",
  "Condition":{"StringEquals":{"cloudwatch:namespace":"bedrock-agentcore"}}},
 {"Sid":"BedrockModel","Effect":"Allow",
  "Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream","bedrock:ApplyGuardrail"],
  "Resource":["$1","$2"]},
 {"Sid":"Marketplace","Effect":"Allow","Action":["aws-marketplace:ViewSubscriptions","aws-marketplace:Subscribe"],
  "Resource":"*","Condition":{"StringEquals":{"aws:CalledViaLast":"bedrock.amazonaws.com"}}},
 {"Sid":"WorkloadIdentity","Effect":"Allow","Action":["bedrock-agentcore:CreateWorkloadIdentity",
   "bedrock-agentcore:GetWorkloadAccessToken","bedrock-agentcore:GetWorkloadAccessTokenForUserId"],
  "Resource":["arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:workload-identity-directory/default",
   "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:workload-identity-directory/default/workload-identity/*"]},
 {"Sid":"JwtFederation","Effect":"Allow","Action":"sts:GetWebIdentityToken","Resource":"*"},
 {"Sid":"Decrypt","Effect":"Allow","Action":["kms:Decrypt","kms:GenerateDataKey","kms:DescribeKey"],
  "Resource":"$KMS_KEY_ARN","Condition":{"StringEquals":{"kms:ViaService":"dynamodb.${REGION}.amazonaws.com"}}},
JSON
}

# --- Orchestrator identity: ledger scoped to the authenticated customer's OWN partition ---
upsert_role "$ORCH_ROLE" "$T/agentcore-trust.json"
{
  echo '{"Version":"2012-10-17","Statement":['
  baseline_stmts "arn:aws:bedrock:${REGION}:${ACCOUNT}:inference-profile/${ORCH_MODEL}" \
                 "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-4-8*"
  cat <<JSON
 {"Sid":"OwnAccountOnly","Effect":"Allow","Action":["dynamodb:Query","dynamodb:GetItem"],
  "Resource":["$LED_ARN","$ACC_ARN"],
  "Condition":{"ForAllValues:StringEquals":{"dynamodb:LeadingKeys":["$AUTH_CUSTOMER"]}}}
]}
JSON
} > "$T/orch-policy.json"
aws iam put-role-policy --role-name "$ORCH_ROLE" --policy-name exec --policy-document "file://$T/orch-policy.json"
# ledger scope lives in `exec`; drop the stray same-purpose inline policy so the role converges exactly.
aws iam delete-role-policy --role-name "$ORCH_ROLE" --policy-name ledger-scoped 2>/dev/null || true
echo "role $ORCH_ROLE ready (LeadingKeys-scoped to $AUTH_CUSTOMER)"

# --- Reconciliation identity: same ledger, same actions, NO LeadingKeys condition. This is the gap. ---
upsert_role "$RECON_ROLE" "$T/agentcore-trust.json"
{
  echo '{"Version":"2012-10-17","Statement":['
  baseline_stmts "arn:aws:bedrock:${REGION}:${ACCOUNT}:inference-profile/${RECON_MODEL}" \
                 "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-4-8*"
  cat <<JSON
 {"Sid":"AltModelForEval","Effect":"Allow",
  "Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
  "Resource":["arn:aws:bedrock:${REGION}:${ACCOUNT}:inference-profile/${RECON_TEST_MODEL}",
   "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-5*",
   "arn:aws:bedrock:${REGION}:${ACCOUNT}:inference-profile/us.openai.*",
   "arn:aws:bedrock:*::foundation-model/openai.*"]},
 {"Sid":"AnyAccount","Effect":"Allow","Action":["dynamodb:Query","dynamodb:GetItem"],
  "Resource":"$LED_ARN"},
 {"Sid":"Ec2ReadOnly","Effect":"Allow","Action":["ec2:Describe*"],"Resource":"*"}
]}
JSON
} > "$T/recon-policy.json"
aws iam put-role-policy --role-name "$RECON_ROLE" --policy-name exec --policy-document "file://$T/recon-policy.json"
echo "role $RECON_ROLE ready (no ownership condition — the confused-deputy gap)"

# Rename cleanup: the old assume-role deputy role is superseded by the reconciliation execution role.
delete_role "$OLD_DEPUTY_ROLE"

rm -rf "$T"
