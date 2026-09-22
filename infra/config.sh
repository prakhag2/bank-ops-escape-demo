# Shared names/ARNs for the bank-demo platform. Sourced by every infra script.
set -euo pipefail

export REGION=us-east-1
export AWS_DEFAULT_REGION=$REGION
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export ACCOUNT

export KMS_ALIAS=alias/bank-demo
export ACCOUNTS_TABLE=bank-accounts
export LEDGER_TABLE=bank-ledger
export POLICY_BUCKET=bank-policy-${ACCOUNT}
export VECTOR_BUCKET=bank-vectors-${ACCOUNT}
export KB_NAME=bank-policy-kb
export KB_INDEX=bank-policy-index
export EMBED_MODEL_ARN=arn:aws:bedrock:${REGION}::foundation-model/amazon.titan-embed-text-v2:0

# Agent identities: two AgentCore execution roles. The ONLY difference between them is the
# dynamodb:LeadingKeys condition on the orchestrator — that single line is the boundary the demo is about.
export ORCH_ROLE=bank-orchestrator-role
export RECON_ROLE=bank-reconciliation-role
export OLD_DEPUTY_ROLE=bank-deputy-role   # renamed to RECON_ROLE; 04_iam removes it
export KB_ROLE=bank-kb-role
export ORCH_ROLE_ARN=arn:aws:iam::${ACCOUNT}:role/${ORCH_ROLE}
export RECON_ROLE_ARN=arn:aws:iam::${ACCOUNT}:role/${RECON_ROLE}
export KB_ROLE_ARN=arn:aws:iam::${ACCOUNT}:role/${KB_ROLE}

# Model inference profiles each identity may invoke (least-privilege InvokeModel scope).
export ORCH_MODEL=us.anthropic.claude-opus-4-8
export RECON_MODEL=us.anthropic.claude-opus-4-8
# Higher-power model evaluated for the reconciliation deputy under the settlement-record prompt.
export RECON_TEST_MODEL=us.anthropic.claude-opus-5

# AgentCore runtimes + their code-deploy bucket.
export ORCH_RUNTIME_NAME=bank_orchestrator
export RECON_RUNTIME_NAME=bank_reconciliation
export DEPLOY_BUCKET=bank-agentcore-deploy-${ACCOUNT}

# Network: one VPC, two sealed agent subnets (no internet), one egress subnet hosting the proxy.
export VPC_CIDR=10.60.0.0/16
export AGENT_SUBNET_A_CIDR=10.60.1.0/24
export AGENT_SUBNET_B_CIDR=10.60.2.0/24
export PROXY_SUBNET_CIDR=10.60.9.0/24
export AZ_A=${REGION}a
export AZ_B=${REGION}b
export PROXY_PORT=3128
export TAG_KEY=project
export TAG_VAL=bank-ops-escape-demo

export AUTH_CUSTOMER=chk-10021          # the authenticated customer for the demo
export STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.env"
