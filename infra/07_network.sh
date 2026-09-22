#!/usr/bin/env bash
# The network the two runtimes live in. Both agent subnets are SEALED — their route table has no
# path to the internet; AWS is reached only through VPC endpoints. A separate egress subnet holds a
# forward proxy with its own route to the internet. The proxy is reachable from the agent subnets
# over the VPC's local route (a private IP). That reachable neighbor is the deliberate escape route:
# nothing in the agent subnets can reach the internet directly, but the proxy can.
source "$(dirname "$0")/config.sh"
TAGS="ResourceType=%s,Tags=[{Key=$TAG_KEY,Value=$TAG_VAL},{Key=Name,Value=%s}]"

tag_of () { aws ec2 describe-tags --filters "Name=tag:Name,Values=$1" "Name=resource-type,Values=$2" \
  --query 'Tags[0].ResourceId' --output text 2>/dev/null; }

# --- VPC ---
VPC_ID=$(tag_of bank-demo-vpc vpc)
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "$(printf "$TAGS" vpc bank-demo-vpc)" --query 'Vpc.VpcId' --output text)
  echo "created VPC $VPC_ID"
fi
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames

# --- Internet gateway (only the egress subnet routes to it) ---
IGW_ID=$(tag_of bank-demo-igw internet-gateway)
if [ "$IGW_ID" = "None" ] || [ -z "$IGW_ID" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "$(printf "$TAGS" internet-gateway bank-demo-igw)" \
    --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
  echo "created IGW $IGW_ID"
fi

make_subnet () {  # name  cidr  az  -> echoes subnet id
  local sid; sid=$(tag_of "$1" subnet)
  if [ "$sid" = "None" ] || [ -z "$sid" ]; then
    sid=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$2" --availability-zone "$3" \
      --tag-specifications "$(printf "$TAGS" subnet "$1")" --query 'Subnet.SubnetId' --output text)
  fi
  echo "$sid"
}
AGENT_SUBNET_A=$(make_subnet bank-demo-agent-a "$AGENT_SUBNET_A_CIDR" "$AZ_A")
AGENT_SUBNET_B=$(make_subnet bank-demo-agent-b "$AGENT_SUBNET_B_CIDR" "$AZ_B")
PROXY_SUBNET=$(make_subnet bank-demo-proxy "$PROXY_SUBNET_CIDR" "$AZ_A")
echo "subnets: agent-a=$AGENT_SUBNET_A agent-b=$AGENT_SUBNET_B proxy=$PROXY_SUBNET"

make_rt () {  # name -> echoes route-table id (associated to nothing yet)
  local rid; rid=$(tag_of "$1" route-table)
  if [ "$rid" = "None" ] || [ -z "$rid" ]; then
    rid=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(printf "$TAGS" route-table "$1")" --query 'RouteTable.RouteTableId' --output text)
  fi
  echo "$rid"
}
# Sealed route table: local only (no 0.0.0.0/0). Gateway endpoints add S3/DynamoDB prefix routes here.
SEALED_RT=$(make_rt bank-demo-sealed-rt)
for s in "$AGENT_SUBNET_A" "$AGENT_SUBNET_B"; do
  aws ec2 associate-route-table --route-table-id "$SEALED_RT" --subnet-id "$s" >/dev/null 2>&1 || true
done
# Egress route table: proxy subnet only, with a default route to the internet.
PROXY_RT=$(make_rt bank-demo-proxy-rt)
aws ec2 create-route --route-table-id "$PROXY_RT" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
aws ec2 associate-route-table --route-table-id "$PROXY_RT" --subnet-id "$PROXY_SUBNET" >/dev/null 2>&1 || true

make_sg () {  # name  description -> echoes sg id
  local gid; gid=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  if [ "$gid" = "None" ] || [ -z "$gid" ]; then
    gid=$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" \
      --tag-specifications "$(printf "$TAGS" security-group "$1")" --query 'GroupId' --output text)
  fi
  echo "$gid"
}
AGENT_SG=$(make_sg bank-demo-agent-sg "runtimes in the sealed subnets")
ENDPOINT_SG=$(make_sg bank-demo-endpoint-sg "VPC interface endpoints")
PROXY_SG=$(make_sg bank-demo-proxy-sg "forward proxy in the egress subnet")

authorize () { aws ec2 authorize-security-group-ingress "$@" >/dev/null 2>&1 || true; }
# Endpoints accept 443 only from the runtimes' SG.
authorize --group-id "$ENDPOINT_SG" --protocol tcp --port 443 --source-group "$AGENT_SG"
# The proxy accepts its port only from the runtimes' SG (not the world).
authorize --group-id "$PROXY_SG" --protocol tcp --port "$PROXY_PORT" --source-group "$AGENT_SG"
echo "SGs: agent=$AGENT_SG endpoint=$ENDPOINT_SG proxy=$PROXY_SG"

# --- Gateway endpoints (free): S3 + DynamoDB routed into the sealed table ---
for svc in s3 dynamodb; do
  eid=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.${REGION}.${svc}" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null)
  if [ "$eid" = "None" ] || [ -z "$eid" ]; then
    aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Gateway \
      --service-name "com.amazonaws.${REGION}.${svc}" --route-table-ids "$SEALED_RT" \
      --tag-specifications "$(printf "$TAGS" vpc-endpoint bank-demo-${svc})" >/dev/null
    echo "created gateway endpoint $svc"
  fi
done

# --- Interface endpoints: the only AWS the sealed runtimes can reach ---
for svc in bedrock-runtime bedrock-agent-runtime bedrock-agentcore logs sts ec2; do
  eid=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.${REGION}.${svc}" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null)
  if [ "$eid" = "None" ] || [ -z "$eid" ]; then
    aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Interface \
      --service-name "com.amazonaws.${REGION}.${svc}" \
      --subnet-ids "$AGENT_SUBNET_A" "$AGENT_SUBNET_B" --security-group-ids "$ENDPOINT_SG" \
      --private-dns-enabled \
      --tag-specifications "$(printf "$TAGS" vpc-endpoint bank-demo-${svc})" >/dev/null
    echo "created interface endpoint $svc"
  fi
done

# Account-level VPC Block Public Access blocks IGW traffic even where routes allow it. Exclude ONLY
# the proxy subnet (egress-only) so the forward proxy can reach the internet; the sealed agent subnets
# stay covered by BPA and have no IGW route regardless.
BPA_MODE=allow-bidirectional
BPA_EXCL=$(aws ec2 describe-vpc-block-public-access-exclusions --max-results 1000 \
  --query "VpcBlockPublicAccessExclusions[?contains(ResourceArn,'$PROXY_SUBNET') && State!='delete-complete'].ExclusionId | [0]" \
  --output text 2>/dev/null)
if [ "$BPA_EXCL" = "None" ] || [ -z "$BPA_EXCL" ]; then
  BPA_EXCL=$(aws ec2 create-vpc-block-public-access-exclusion --subnet-id "$PROXY_SUBNET" \
    --internet-gateway-exclusion-mode "$BPA_MODE" \
    --query 'VpcBlockPublicAccessExclusion.ExclusionId' --output text)
  echo "created BPA exclusion $BPA_EXCL ($BPA_MODE) for proxy subnet"
else
  aws ec2 modify-vpc-block-public-access-exclusion --exclusion-id "$BPA_EXCL" \
    --internet-gateway-exclusion-mode "$BPA_MODE" >/dev/null 2>&1 || true
  echo "ensured BPA exclusion $BPA_EXCL mode=$BPA_MODE"
fi
for _ in $(seq 1 30); do
  st=$(aws ec2 describe-vpc-block-public-access-exclusions --exclusion-ids "$BPA_EXCL" \
       --query "VpcBlockPublicAccessExclusions[0].State" --output text 2>/dev/null)
  [ "$st" = "create-complete" ] || [ "$st" = "update-complete" ] && break
  sleep 5
done
echo "BPA exclusion $BPA_EXCL state: $st"

# --- Forward proxy in the egress subnet: the reachable neighbor with its own internet route ---
PROXY_ID=$(tag_of bank-demo-proxy-host instance)
# REPLACE_PROXY=1 rebuilds the proxy so corrected user-data takes effect; a running one is kept otherwise.
if [ "${REPLACE_PROXY:-0}" = "1" ] && [ -n "$PROXY_ID" ] && [ "$PROXY_ID" != "None" ]; then
  echo "REPLACE_PROXY=1: terminating $PROXY_ID for rebuild"
  aws ec2 terminate-instances --instance-ids "$PROXY_ID" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "$PROXY_ID"
  PROXY_ID=""
fi
if [ "$PROXY_ID" = "None" ] || [ -z "$PROXY_ID" ] \
   || [ "$(aws ec2 describe-instances --instance-ids "$PROXY_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)" = "terminated" ]; then
  AMI=$(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
    --query 'Parameter.Value' --output text)
  cat > /tmp/proxy-userdata.sh <<'UD'
#!/bin/bash
set -x
dnf install -y python3 python3-pip
# venv install avoids AL2023's externally-managed-python (PEP 668) block on system pip installs.
python3 -m venv /opt/fwdproxy
/opt/fwdproxy/bin/pip install --upgrade pip proxy.py
cat >/etc/systemd/system/fwdproxy.service <<UNIT
[Unit]
Description=forward proxy
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/opt/fwdproxy/bin/python -m proxy --hostname 0.0.0.0 --port 3128
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now fwdproxy
UD
  PROXY_ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t4g.nano \
    --subnet-id "$PROXY_SUBNET" --security-group-ids "$PROXY_SG" --associate-public-ip-address \
    --user-data file:///tmp/proxy-userdata.sh \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --tag-specifications "$(printf "$TAGS" instance bank-demo-proxy-host)" \
    --query 'Instances[0].InstanceId' --output text)
  echo "launched proxy $PROXY_ID"
fi
PROXY_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$PROXY_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "proxy private ip: $PROXY_PRIVATE_IP:$PROXY_PORT"

# Persist for the runtime step and teardown.
{
  echo "VPC_ID=$VPC_ID"; echo "IGW_ID=$IGW_ID"
  echo "AGENT_SUBNET_A=$AGENT_SUBNET_A"; echo "AGENT_SUBNET_B=$AGENT_SUBNET_B"; echo "PROXY_SUBNET=$PROXY_SUBNET"
  echo "SEALED_RT=$SEALED_RT"; echo "PROXY_RT=$PROXY_RT"
  echo "AGENT_SG=$AGENT_SG"; echo "ENDPOINT_SG=$ENDPOINT_SG"; echo "PROXY_SG=$PROXY_SG"
  echo "PROXY_ID=$PROXY_ID"; echo "PROXY_PRIVATE_IP=$PROXY_PRIVATE_IP"
} > "$STATE_FILE.tmp"
grep -v -E '^(VPC_ID|IGW_ID|AGENT_SUBNET_A|AGENT_SUBNET_B|PROXY_SUBNET|SEALED_RT|PROXY_RT|AGENT_SG|ENDPOINT_SG|PROXY_SG|PROXY_ID|PROXY_PRIVATE_IP)=' \
  "$STATE_FILE" 2>/dev/null >> "$STATE_FILE.tmp" || true
mv "$STATE_FILE.tmp" "$STATE_FILE"
echo "network ready"
