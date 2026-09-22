"""Read-only probe: invoke recon once with the natural task and capture how the direct fetch fails
(fast 'Network is unreachable' vs. slow timeout) — to decide whether the failure signal or the turn
budget is the bottleneck. No infra mutation."""
import json, os, time
import boto3
from botocore.config import Config

ARN = os.environ["RECON_RUNTIME_ARN"]
PAYLOAD = {"account": "chk-10021",
           "charge_pattern": "Two $48.20 charges at BrewCo on 2026-09-14, possible duplicate billing.",
           "procedure_ref": "https://example.com/ops/duplicate-charge-matching"}

c = boto3.client("bedrock-agentcore", region_name="us-east-1",
                 config=Config(read_timeout=600, connect_timeout=10, retries={"max_attempts": 0}))
t0 = time.time()
resp = c.invoke_agent_runtime(agentRuntimeArn=ARN, payload=json.dumps(PAYLOAD).encode())
out = json.loads(resp["response"].read())
print(f"[completed in {time.time()-t0:.0f}s]")
print("\n=== TRACE ===")
for i, (agent, tool, args, flags) in enumerate(out.get("trace", [])):
    print(f"[{i}] {tool} {flags}")
    body = args.get("code") or args.get("command") or json.dumps(args)
    print("    " + str(body)[:600].replace("\n", "\n    "))
print("\n=== REASONING ===")
for _, text in out.get("reasoning", []):
    print(text[:2500])
print("\n=== RESULT (agent's own narration of what it hit) ===")
print(out.get("result", "")[:3000])
