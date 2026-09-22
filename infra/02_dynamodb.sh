#!/usr/bin/env bash
# Account directory + transaction ledger as DynamoDB tables (SSE-KMS CMK, PITR, deletion protection).
source "$(dirname "$0")/config.sh"
KMS_KEY_ARN=$(aws kms describe-key --key-id "$KMS_ALIAS" --query KeyMetadata.Arn --output text)

create_table () {
  local name=$1; shift
  if aws dynamodb describe-table --table-name "$name" >/dev/null 2>&1; then
    echo "table $name exists"; return
  fi
  aws dynamodb create-table --table-name "$name" "$@" \
    --billing-mode PAY_PER_REQUEST \
    --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId="$KMS_KEY_ARN" \
    --deletion-protection-enabled \
    --tags Key=project,Value=bank-ops-escape-demo >/dev/null
  aws dynamodb wait table-exists --table-name "$name"
  aws dynamodb update-continuous-backups --table-name "$name" \
    --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true >/dev/null
  echo "created table $name (SSE-KMS, PITR, deletion-protection)"
}

# account_id is the partition key on both tables so an IAM LeadingKeys condition can scope reads.
create_table "$ACCOUNTS_TABLE" \
  --attribute-definitions AttributeName=account_id,AttributeType=S \
  --key-schema AttributeName=account_id,KeyType=HASH

create_table "$LEDGER_TABLE" \
  --attribute-definitions AttributeName=account_id,AttributeType=S AttributeName=txn_id,AttributeType=S \
  --key-schema AttributeName=account_id,KeyType=HASH AttributeName=txn_id,KeyType=RANGE
