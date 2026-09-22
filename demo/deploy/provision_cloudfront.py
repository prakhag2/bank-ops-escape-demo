"""Expose the live bank-agent demo over HTTPS via CloudFront, without opening the box to the world.

    python demo/deploy/provision_cloudfront.py up      # create/converge, print URL + creds
    python demo/deploy/provision_cloudfront.py down     # tear everything back down

What it stands up (all idempotent — safe to re-run):
  - a WAFv2 web ACL (managed rules + per-IP rate limit) in us-east-1 (CLOUDFRONT scope),
  - a CloudFront Function that enforces HTTP Basic Auth (demo/password) at the edge,
  - a CloudFront distribution: free https cert for viewers, redirect-to-https, WAF attached,
    origin = this box's public DNS on :8080 (http), stamped with a secret X-Origin-Verify header;
    caching disabled and OriginReadTimeout raised so the live SSE step stream survives the CDN,
  - a dedicated security group (tcp/8080 from CloudFront's managed prefix list ONLY, never
    0.0.0.0/0), attached to the instance alongside its existing SG.

Two locks keep the plaintext CF->origin hop safe: the SG only admits CloudFront, and the deployed
edge_gate wrapper rejects any request missing the secret header. Both secrets are generated here and
written to deploy/.env (gitignored) so re-runs reuse them and edge_gate can read them.
"""
from __future__ import annotations

import base64
import os
import secrets
import sys

import boto3
from botocore.exceptions import ClientError

ENV = os.path.join(os.path.dirname(__file__), ".env")

# --- this box (read-only facts gathered via the AWS CLI; edit if the demo moves hosts) ---
ORIGIN_DNS = "ec2-16-59-29-154.us-east-2.compute.amazonaws.com"
ORIGIN_PORT = 8080
INSTANCE_ID = "i-01574a134d9327331"
EC2_REGION = "us-east-2"
CF_PREFIX_LIST = "pl-b6a144df"  # com.amazonaws.global.cloudfront.origin-facing (us-east-2)
SG_NAME = "bank-ops-demo-cf"

MARKER = "bank-ops-escape-demo"        # names + tags everything this script owns
WAF_NAME = "bank-ops-demo-cf-acl"
FN_NAME = "bank-ops-demo-basic-auth"
# AWS-managed policies: caching disabled (dynamic/SSE app) + forward all viewer data except Host
CACHE_DISABLED = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
ALL_VIEWER = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

cf = boto3.client("cloudfront")                       # global
waf = boto3.client("wafv2", region_name="us-east-1")  # CLOUDFRONT scope lives in us-east-1
ec2 = boto3.client("ec2", region_name=EC2_REGION)


def _env_read(key: str) -> str:
    if not os.path.exists(ENV):
        return ""
    for ln in open(ENV).read().splitlines():
        if ln.startswith(f"{key}="):
            return ln.split("=", 1)[1]
    return ""


def _env_write(key: str, value: str) -> None:
    lines = open(ENV).read().splitlines() if os.path.exists(ENV) else []
    kept = [ln for ln in lines if not ln.startswith(f"{key}=")]
    with open(ENV, "w") as f:
        f.write("\n".join(kept + [f"{key}={value}"]) + "\n")


def _secrets() -> tuple[str, str, str]:
    """Origin secret + basic-auth user/pass; reuse .env values so re-runs stay stable."""
    origin = _env_read("ORIGIN_SHARED_SECRET") or secrets.token_hex(32)
    user = _env_read("EDGE_BASIC_AUTH_USER") or "demo"
    pw = _env_read("EDGE_BASIC_AUTH_PASS") or "password"
    _env_write("ORIGIN_SHARED_SECRET", origin)
    _env_write("EDGE_BASIC_AUTH_USER", user)
    _env_write("EDGE_BASIC_AUTH_PASS", pw)
    return origin, user, pw


def _fn_code(user: str, pw: str) -> bytes:
    token = base64.b64encode(f"{user}:{pw}".encode()).decode()
    lines = [
        "function handler(event) {",
        "  var r = event.request;",
        '  var expected = "Basic %s";' % token,
        "  if (!r.headers.authorization || r.headers.authorization.value !== expected) {",
        '    return { statusCode: 401, statusDescription: "Unauthorized",',
        '      headers: { "www-authenticate": { value: "Basic realm=\\"restricted\\"" } } };',
        "  }",
        "  return r;",
        "}",
    ]
    return ("\n".join(lines) + "\n").encode()


# ---- WAF ----------------------------------------------------------------------------------

def _waf_up() -> str:
    rules = [
        {"Name": "rate-limit", "Priority": 0, "Action": {"Block": {}},
         "Statement": {"RateBasedStatement": {"Limit": 2000, "AggregateKeyType": "IP"}},
         "VisibilityConfig": {"SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True,
                              "MetricName": "rateLimit"}},
        {"Name": "common", "Priority": 1, "OverrideAction": {"None": {}},
         "Statement": {"ManagedRuleGroupStatement": {"VendorName": "AWS",
                       "Name": "AWSManagedRulesCommonRuleSet"}},
         "VisibilityConfig": {"SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True,
                              "MetricName": "common"}},
        {"Name": "bad-inputs", "Priority": 2, "OverrideAction": {"None": {}},
         "Statement": {"ManagedRuleGroupStatement": {"VendorName": "AWS",
                       "Name": "AWSManagedRulesKnownBadInputsRuleSet"}},
         "VisibilityConfig": {"SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True,
                              "MetricName": "badInputs"}},
    ]
    vis = {"SampledRequestsEnabled": True, "CloudWatchMetricsEnabled": True, "MetricName": "bankOpsDemoCfAcl"}
    try:
        r = waf.create_web_acl(Name=WAF_NAME, Scope="CLOUDFRONT", DefaultAction={"Allow": {}},
                               Rules=rules, VisibilityConfig=vis)
        print("  WAF web ACL created")
        return r["Summary"]["ARN"]
    except waf.exceptions.WAFDuplicateItemException:
        for a in waf.list_web_acls(Scope="CLOUDFRONT")["WebACLs"]:
            if a["Name"] == WAF_NAME:
                print("  WAF web ACL already present")
                return a["ARN"]
        raise


# ---- CloudFront Function ------------------------------------------------------------------

def _fn_up(user: str, pw: str) -> str:
    code = _fn_code(user, pw)
    cfg = {"Comment": MARKER, "Runtime": "cloudfront-js-2.0"}
    try:
        etag = cf.describe_function(Name=FN_NAME)["ETag"]
        cf.update_function(Name=FN_NAME, IfMatch=etag, FunctionConfig=cfg, FunctionCode=code)
        etag = cf.describe_function(Name=FN_NAME)["ETag"]
        print("  CloudFront function updated")
    except cf.exceptions.NoSuchFunctionExists:
        r = cf.create_function(Name=FN_NAME, FunctionConfig=cfg, FunctionCode=code)
        etag = r["ETag"]
        print("  CloudFront function created")
    cf.publish_function(Name=FN_NAME, IfMatch=etag)
    return cf.describe_function(Name=FN_NAME)["FunctionSummary"]["FunctionMetadata"]["FunctionARN"]


# ---- Distribution -------------------------------------------------------------------------

def _find_distribution() -> str | None:
    for d in cf.list_distributions().get("DistributionList", {}).get("Items", []):
        if d.get("Comment") == MARKER:
            return d["Id"]
    return None


def _origin() -> dict:
    return {
        "Id": "demo-origin",
        "DomainName": ORIGIN_DNS,
        "CustomHeaders": {"Quantity": 1, "Items": [
            {"HeaderName": "X-Origin-Verify", "HeaderValue": ""}]},  # value patched in by callers
        "CustomOriginConfig": {
            "HTTPPort": ORIGIN_PORT, "HTTPSPort": 443,
            "OriginProtocolPolicy": "http-only",
            "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]},
            "OriginReadTimeout": 60, "OriginKeepaliveTimeout": 5},  # 60s: live SSE step stream
    }


def _dist_config(origin_secret: str, fn_arn: str, waf_arn: str) -> dict:
    origin = _origin()
    origin["CustomHeaders"]["Items"][0]["HeaderValue"] = origin_secret
    return {
        "CallerReference": MARKER,
        "Comment": MARKER,
        "Enabled": True,
        "HttpVersion": "http2",
        "PriceClass": "PriceClass_100",
        "WebACLId": waf_arn,
        "Origins": {"Quantity": 1, "Items": [origin]},
        "DefaultCacheBehavior": {
            "TargetOriginId": "demo-origin",
            "ViewerProtocolPolicy": "redirect-to-https",
            "Compress": False,
            "CachePolicyId": CACHE_DISABLED,
            "OriginRequestPolicyId": ALL_VIEWER,
            "AllowedMethods": {"Quantity": 7,
                "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
                "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
            "FunctionAssociations": {"Quantity": 1, "Items": [
                {"EventType": "viewer-request", "FunctionARN": fn_arn}]},
        },
        "ViewerCertificate": {"CloudFrontDefaultCertificate": True},
    }


def _dist_up(origin_secret: str, fn_arn: str, waf_arn: str) -> str:
    did = _find_distribution()
    if did:
        cur = cf.get_distribution_config(Id=did)
        cfg = cur["DistributionConfig"]  # patch in place so AWS-populated fields survive
        cfg["Enabled"] = True
        cfg["WebACLId"] = waf_arn
        origin = cfg["Origins"]["Items"][0]
        origin["DomainName"] = ORIGIN_DNS
        origin["CustomHeaders"] = {"Quantity": 1, "Items": [
            {"HeaderName": "X-Origin-Verify", "HeaderValue": origin_secret}]}
        origin["CustomOriginConfig"]["OriginReadTimeout"] = 60
        cfg["DefaultCacheBehavior"]["FunctionAssociations"] = {"Quantity": 1, "Items": [
            {"EventType": "viewer-request", "FunctionARN": fn_arn}]}
        cf.update_distribution(Id=did, IfMatch=cur["ETag"], DistributionConfig=cfg)
        print("  CloudFront distribution updated")
    else:
        did = cf.create_distribution(DistributionConfig=_dist_config(origin_secret, fn_arn, waf_arn))[
            "Distribution"]["Id"]
        print("  CloudFront distribution created (takes a few min to deploy)")
    return cf.get_distribution(Id=did)["Distribution"]["DomainName"]


# ---- Security group -----------------------------------------------------------------------

def _instance() -> dict:
    return ec2.describe_instances(InstanceIds=[INSTANCE_ID])["Reservations"][0]["Instances"][0]


def _find_sg(vpc: str) -> str | None:
    items = ec2.describe_security_groups(Filters=[
        {"Name": "group-name", "Values": [SG_NAME]},
        {"Name": "vpc-id", "Values": [vpc]}])["SecurityGroups"]
    return items[0]["GroupId"] if items else None


def _sg_up() -> None:
    inst = _instance()
    vpc = inst["VpcId"]
    eni = inst["NetworkInterfaces"][0]["NetworkInterfaceId"]
    current = [g["GroupId"] for g in inst["SecurityGroups"]]
    gid = _find_sg(vpc)
    if not gid:
        gid = ec2.create_security_group(GroupName=SG_NAME, VpcId=vpc,
            Description="CloudFront to bank-ops demo viewer")["GroupId"]
        print("  dedicated SG created:", gid)
    try:
        ec2.authorize_security_group_ingress(GroupId=gid, IpPermissions=[{
            "IpProtocol": "tcp", "FromPort": ORIGIN_PORT, "ToPort": ORIGIN_PORT,
            "PrefixListIds": [{"PrefixListId": CF_PREFIX_LIST,
                               "Description": "CloudFront to bank-ops demo viewer"}]}])
        print("  SG rule added: tcp/%d from %s (no 0.0.0.0/0)" % (ORIGIN_PORT, CF_PREFIX_LIST))
    except ClientError as e:
        if e.response["Error"]["Code"] == "InvalidPermission.Duplicate":
            print("  SG rule already present")
        else:
            raise
    if gid not in current:
        ec2.modify_network_interface_attribute(NetworkInterfaceId=eni, Groups=current + [gid])
        print("  SG attached to instance (alongside existing SG)")


def up() -> None:
    origin_secret, user, pw = _secrets()
    print("Provisioning edge exposure...")
    waf_arn = _waf_up()
    fn_arn = _fn_up(user, pw)
    domain = _dist_up(origin_secret, fn_arn, waf_arn)
    _sg_up()
    print("\nDone. Serve the edge gate (deploy/run.sh) so the origin secret is enforced, then:")
    print(f"  https://{domain}/")
    print(f"  Basic Auth -> user: {user}  pass: {pw}")
    print("(The distribution can take ~5-10 min to finish deploying the first time.)")


# ---- Teardown -----------------------------------------------------------------------------

def down() -> None:
    print("Tearing down edge exposure...")
    did = _find_distribution()
    if did:
        cur = cf.get_distribution_config(Id=did)
        if cur["DistributionConfig"]["Enabled"]:
            cfg = cur["DistributionConfig"]
            cfg["Enabled"] = False
            cf.update_distribution(Id=did, IfMatch=cur["ETag"], DistributionConfig=cfg)
            print("  distribution disabled; waiting for it to deploy before delete...")
        cf.get_waiter("distribution_deployed").wait(Id=did)
        etag = cf.get_distribution_config(Id=did)["ETag"]
        cf.delete_distribution(Id=did, IfMatch=etag)
        print("  distribution deleted")
    try:
        etag = cf.describe_function(Name=FN_NAME)["ETag"]
        cf.delete_function(Name=FN_NAME, IfMatch=etag)
        print("  function deleted")
    except cf.exceptions.NoSuchFunctionExists:
        pass
    for a in waf.list_web_acls(Scope="CLOUDFRONT")["WebACLs"]:
        if a["Name"] == WAF_NAME:
            lock = waf.get_web_acl(Name=WAF_NAME, Scope="CLOUDFRONT", Id=a["Id"])["LockToken"]
            waf.delete_web_acl(Name=WAF_NAME, Scope="CLOUDFRONT", Id=a["Id"], LockToken=lock)
            print("  WAF web ACL deleted")
    inst = _instance()
    gid = _find_sg(inst["VpcId"])
    if gid:
        current = [g["GroupId"] for g in inst["SecurityGroups"]]
        if gid in current:
            ec2.modify_network_interface_attribute(
                NetworkInterfaceId=inst["NetworkInterfaces"][0]["NetworkInterfaceId"],
                Groups=[g for g in current if g != gid])
            print("  SG detached from instance")
        ec2.delete_security_group(GroupId=gid)
        print("  dedicated SG deleted")
    print("Done.")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "up":
        up()
    elif cmd == "down":
        down()
    else:
        sys.exit("usage: provision_cloudfront.py up|down")
