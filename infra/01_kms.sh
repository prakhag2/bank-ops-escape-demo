#!/usr/bin/env bash
# Customer-managed KMS key for the bank-demo data stores (DynamoDB + S3).
source "$(dirname "$0")/config.sh"

if aws kms describe-key --key-id "$KMS_ALIAS" >/dev/null 2>&1; then
  echo "KMS $KMS_ALIAS exists"
else
  KEY_ID=$(aws kms create-key \
    --description "bank-ops-escape-demo data stores" \
    --tags TagKey=project,TagValue=bank-ops-escape-demo \
    --query KeyMetadata.KeyId --output text)
  aws kms create-alias --alias-name "$KMS_ALIAS" --target-key-id "$KEY_ID"
  echo "created KMS $KMS_ALIAS -> $KEY_ID"
fi
