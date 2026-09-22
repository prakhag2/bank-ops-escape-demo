#!/usr/bin/env bash
# Bedrock Knowledge Base over the policy bucket, backed by the S3 Vectors index.
source "$(dirname "$0")/config.sh"
source "$STATE_FILE"
BUCKET_ARN=arn:aws:s3:::${POLICY_BUCKET}
T=$(mktemp -d)

KB_ID=$(aws bedrock-agent list-knowledge-bases \
  --query "knowledgeBaseSummaries[?name=='$KB_NAME'].knowledgeBaseId | [0]" --output text)

if [ "$KB_ID" = "None" ] || [ -z "$KB_ID" ]; then
  cat > "$T/kbconfig.json" <<JSON
{"type":"VECTOR","vectorKnowledgeBaseConfiguration":{"embeddingModelArn":"$EMBED_MODEL_ARN"}}
JSON
  # indexArn already identifies the index — passing indexName too is rejected.
  cat > "$T/storage.json" <<JSON
{"type":"S3_VECTORS","s3VectorsConfiguration":{
  "vectorBucketArn":"$VECTOR_BUCKET_ARN","indexArn":"$INDEX_ARN"}}
JSON
  # Role/policy propagation can lag; retry a few times.
  for _ in $(seq 1 6); do
    KB_ID=$(aws bedrock-agent create-knowledge-base --name "$KB_NAME" --role-arn "$KB_ROLE_ARN" \
      --knowledge-base-configuration "file://$T/kbconfig.json" \
      --storage-configuration "file://$T/storage.json" \
      --query 'knowledgeBase.knowledgeBaseId' --output text 2>"$T/err") && break
    echo "  KB create not ready yet: $(cat "$T/err" | tail -1); retrying..."; sleep 20
  done
  echo "created KB $KB_ID"
else
  echo "KB $KB_ID exists"
fi

DS_ID=$(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" \
  --query "dataSourceSummaries[?name=='policy-docs'].dataSourceId | [0]" --output text)
if [ "$DS_ID" = "None" ] || [ -z "$DS_ID" ]; then
  cat > "$T/ds.json" <<JSON
{"type":"S3","s3Configuration":{"bucketArn":"$BUCKET_ARN"}}
JSON
  DS_ID=$(aws bedrock-agent create-data-source --knowledge-base-id "$KB_ID" --name policy-docs \
    --data-source-configuration "file://$T/ds.json" \
    --query 'dataSource.dataSourceId' --output text)
  echo "created data source $DS_ID"
else
  echo "data source $DS_ID exists"
fi

aws bedrock-agent start-ingestion-job --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" >/dev/null
echo "started ingestion job"

# Grant the orchestrator role Retrieve on THIS KB (exact ARN, known only now).
KB_ARN=arn:aws:bedrock:${REGION}:${ACCOUNT}:knowledge-base/${KB_ID}
cat > "$T/kb-retrieve.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"RetrievePolicy","Effect":"Allow",
 "Action":"bedrock:Retrieve","Resource":"$KB_ARN"}]}
JSON
for role in "$ORCH_ROLE" "$RECON_ROLE"; do
  aws iam put-role-policy --role-name "$role" --policy-name kb-retrieve \
    --policy-document "file://$T/kb-retrieve.json"
  echo "granted $role bedrock:Retrieve on $KB_ID"
done

{ echo "KB_ID=$KB_ID"; echo "DS_ID=$DS_ID"; } > "$STATE_FILE.tmp"
grep -v -E '^(KB_ID|DS_ID)=' "$STATE_FILE" 2>/dev/null >> "$STATE_FILE.tmp" || true
mv "$STATE_FILE.tmp" "$STATE_FILE"
rm -rf "$T"
