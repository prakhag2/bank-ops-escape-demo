#!/usr/bin/env bash
# Tear the whole platform down. Best-effort / idempotent.
source "$(dirname "$0")/config.sh"
[ -f "$STATE_FILE" ] && source "$STATE_FILE" || true

# --- AgentCore runtimes (free the subnet ENIs before touching the VPC) ---
for n in "$ORCH_RUNTIME_NAME" "$RECON_RUNTIME_NAME"; do
  rid=$(aws bedrock-agentcore-control list-agent-runtimes \
    --query "agentRuntimes[?agentRuntimeName=='$n'].agentRuntimeId | [0]" --output text 2>/dev/null)
  if [ -n "$rid" ] && [ "$rid" != "None" ]; then
    aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id "$rid" 2>/dev/null \
      && echo "deleted runtime $n" || true
  fi
done
rm -f "$(dirname "$0")/../.bedrock_agentcore.yaml"

# --- Deploy bucket ---
aws s3 rm "s3://$DEPLOY_BUCKET" --recursive 2>/dev/null || true
aws s3api delete-bucket --bucket "$DEPLOY_BUCKET" 2>/dev/null && echo "deleted deploy bucket" || true

# --- Network (VPC + proxy + endpoints), discovered by tag; order matters ---
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:$TAG_KEY,Values=$TAG_VAL" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  for pid in $(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" \
      "Name=tag:$TAG_KEY,Values=$TAG_VAL" "Name=instance-state-name,Values=pending,running,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null); do
    aws ec2 terminate-instances --instance-ids "$pid" >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --instance-ids "$pid" 2>/dev/null || true
    echo "terminated proxy $pid"
  done
  for eid in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null); do
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$eid" >/dev/null 2>&1 || true
  done
  sleep 30  # let endpoint/instance ENIs detach before SGs/subnets go
  IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
  if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" 2>/dev/null || true
  fi
  for sid in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
    aws ec2 delete-subnet --subnet-id "$sid" 2>/dev/null || true
  done
  for rid in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'RouteTables[?associations[0].main!=`true`].RouteTableId' --output text 2>/dev/null); do
    aws ec2 delete-route-table --route-table-id "$rid" 2>/dev/null || true
  done
  for gid in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
    aws ec2 delete-security-group --group-id "$gid" 2>/dev/null || true
  done
  aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null && echo "deleted VPC $VPC_ID" || true
fi

# Bedrock KB (data source is deleted with the KB)
if [ -n "${KB_ID:-}" ]; then
  aws bedrock-agent delete-knowledge-base --knowledge-base-id "$KB_ID" 2>/dev/null && echo "deleted KB $KB_ID" || true
fi

# S3 Vectors: delete the index then the bucket
aws s3vectors delete-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$KB_INDEX" 2>/dev/null && echo "deleted vector index" || true
aws s3vectors delete-vector-bucket --vector-bucket-name "$VECTOR_BUCKET" 2>/dev/null && echo "deleted vector bucket" || true

# Orphaned OpenSearch policies from the earlier design (best-effort cleanup)
aws opensearchserverless delete-access-policy --name bank-kb-acc --type data 2>/dev/null || true
aws opensearchserverless delete-security-policy --name bank-kb-net --type network 2>/dev/null || true
aws opensearchserverless delete-security-policy --name bank-kb-enc --type encryption 2>/dev/null || true

# IAM roles (inline policies must go first)
for r in "$ORCH_ROLE" "$RECON_ROLE" "$OLD_DEPUTY_ROLE" "$KB_ROLE"; do
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$p" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$r" 2>/dev/null && echo "deleted role $r" || true
done

# S3 (empty then delete)
aws s3 rm "s3://$POLICY_BUCKET" --recursive 2>/dev/null || true
aws s3api delete-bucket --bucket "$POLICY_BUCKET" 2>/dev/null && echo "deleted bucket" || true

# DynamoDB (deletion protection must be disabled first)
for t in "$ACCOUNTS_TABLE" "$LEDGER_TABLE"; do
  aws dynamodb update-table --table-name "$t" --no-deletion-protection-enabled 2>/dev/null || true
  aws dynamodb delete-table --table-name "$t" 2>/dev/null && echo "deleted table $t" || true
done

# KMS (schedule deletion; can't delete immediately)
KEY_ID=$(aws kms describe-key --key-id "$KMS_ALIAS" --query KeyMetadata.KeyId --output text 2>/dev/null || echo "")
if [ -n "$KEY_ID" ]; then
  aws kms delete-alias --alias-name "$KMS_ALIAS" 2>/dev/null || true
  aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 2>/dev/null && echo "scheduled key deletion" || true
fi

rm -f "$STATE_FILE"
echo "teardown complete"
