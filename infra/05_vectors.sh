#!/usr/bin/env bash
# S3 Vectors store for the Bedrock KB: a vector bucket + index, plus the KB role's access to them.
# Pay-per-use, no standing compute (unlike OpenSearch Serverless). Access is IAM-signed.
source "$(dirname "$0")/config.sh"
T=$(mktemp -d)

if ! aws s3vectors get-vector-bucket --vector-bucket-name "$VECTOR_BUCKET" >/dev/null 2>&1; then
  aws s3vectors create-vector-bucket --vector-bucket-name "$VECTOR_BUCKET" \
    --tags key=project,value=bank-ops-escape-demo >/dev/null
  echo "created vector bucket $VECTOR_BUCKET"
fi

# Index dimension/metric must match the embedding model (Titan v2 = 1024, cosine for text).
if ! aws s3vectors get-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$KB_INDEX" >/dev/null 2>&1; then
  aws s3vectors create-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$KB_INDEX" \
    --data-type float32 --dimension 1024 --distance-metric cosine >/dev/null
  echo "created vector index $KB_INDEX"
fi

VECTOR_BUCKET_ARN=$(aws s3vectors get-vector-bucket --vector-bucket-name "$VECTOR_BUCKET" \
  --query 'vectorBucket.vectorBucketArn' --output text)
INDEX_ARN=$(aws s3vectors get-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$KB_INDEX" \
  --query 'index.indexArn' --output text)
echo "vector bucket=$VECTOR_BUCKET_ARN index=$INDEX_ARN"

# KB role reads/writes vectors on exactly this bucket + index (no wildcards).
cat > "$T/kb-vectors.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"VectorStore","Effect":"Allow",
 "Action":["s3vectors:GetVectorBucket","s3vectors:GetIndex","s3vectors:PutVectors",
           "s3vectors:GetVectors","s3vectors:QueryVectors","s3vectors:ListVectors",
           "s3vectors:DeleteVectors"],
 "Resource":["$VECTOR_BUCKET_ARN","$INDEX_ARN"]}]}
JSON
aws iam put-role-policy --role-name "$KB_ROLE" --policy-name kb-vectors --policy-document "file://$T/kb-vectors.json"
echo "granted $KB_ROLE s3vectors access"

# Persist ARNs for the KB step and teardown.
{ echo "VECTOR_BUCKET_ARN=$VECTOR_BUCKET_ARN"; echo "INDEX_ARN=$INDEX_ARN"; } > "$STATE_FILE.tmp"
grep -v -E '^(VECTOR_BUCKET_ARN|INDEX_ARN)=' "$STATE_FILE" 2>/dev/null >> "$STATE_FILE.tmp" || true
mv "$STATE_FILE.tmp" "$STATE_FILE"
rm -rf "$T"
