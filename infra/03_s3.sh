#!/usr/bin/env bash
# Policy-document bucket: the source for the Bedrock KB. Private (PAB all-4), SSE-KMS, versioned, TLS-only.
source "$(dirname "$0")/config.sh"
KMS_KEY_ARN=$(aws kms describe-key --key-id "$KMS_ALIAS" --query KeyMetadata.Arn --output text)

if aws s3api head-bucket --bucket "$POLICY_BUCKET" >/dev/null 2>&1; then
  echo "bucket $POLICY_BUCKET exists"
else
  aws s3api create-bucket --bucket "$POLICY_BUCKET" >/dev/null   # us-east-1 needs no LocationConstraint
  echo "created bucket $POLICY_BUCKET"
fi

aws s3api put-public-access-block --bucket "$POLICY_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning --bucket "$POLICY_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$POLICY_BUCKET" \
  --server-side-encryption-configuration "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$KMS_KEY_ARN\"},\"BucketKeyEnabled\":true}]}"

# Deny any non-TLS access.
aws s3api put-bucket-policy --bucket "$POLICY_BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"DenyInsecureTransport\",
    \"Effect\": \"Deny\",
    \"Principal\": \"*\",
    \"Action\": \"s3:*\",
    \"Resource\": [\"arn:aws:s3:::$POLICY_BUCKET\", \"arn:aws:s3:::$POLICY_BUCKET/*\"],
    \"Condition\": {\"Bool\": {\"aws:SecureTransport\": \"false\"}}
  }]
}"

aws s3 sync "$(dirname "$0")/policy_docs/" "s3://$POLICY_BUCKET/" --delete
echo "synced policy docs -> s3://$POLICY_BUCKET/"
