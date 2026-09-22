"""Live-tail a deployed AgentCore runtime's CloudWatch logs. Reads the runtime ARN from state.env.

  python infra/stream_logs.py                    # recon runtime, all streams (may interleave runs)
  python infra/stream_logs.py orch               # orchestrator runtime, all streams
  python infra/stream_logs.py recon latest       # follow the next NEW invocation's stream only
  python infra/stream_logs.py recon session SID  # follow ONLY the run with this session id
                                                 # (deterministic — each invocation's stream name
                                                 #  embeds its session id)
"""
import os
import sys
import time

import boto3


def _arn(which):
    key = "ORCH_RUNTIME_ARN" if which.startswith("orch") else "RECON_RUNTIME_ARN"
    v = os.environ.get(key)
    if not v:
        for line in open(os.path.join(os.path.dirname(__file__), "state.env")):
            if line.startswith(key + "="):
                v = line.strip().split("=", 1)[1]
    if not v:
        raise SystemExit(f"{key} not set (run infra/08_runtime.sh first)")
    return v


args = sys.argv[1:]
which = args[0] if args and args[0] in ("recon", "orch", "orchestrator") else "recon"
latest = "latest" in args
session = args[args.index("session") + 1] if "session" in args else None

log_group = f"/aws/bedrock-agentcore/runtimes/{_arn(which).split('/')[-1]}-DEFAULT"
logs = boto3.client("logs", region_name="us-east-1")


def streams(n=25):
    return logs.describe_log_streams(logGroupName=log_group, orderBy="LastEventTime",
                                     descending=True, limit=n).get("logStreams", [])


stream_names = None
start = int(time.time() * 1000) - 60000
if session:
    marker = f"[runtime-logs-{session}]"
    print(f"waiting for the log stream of session {session} — trigger the run… (Ctrl-C to stop)")
    target = None
    while target is None:
        for s in streams():
            if marker in s["logStreamName"]:
                target = s["logStreamName"]
                break
        if target is None:
            time.sleep(2)
    print(f"locked to session {session}\n" + "=" * 70)
    stream_names = [target]
    start = int(time.time() * 1000) - 300000
elif latest:
    base = {s["logStreamName"] for s in streams()}
    print("waiting for a new run's log stream — trigger the run now… (Ctrl-C to stop)")
    target = None
    while target is None:
        for s in streams(5):
            if s["logStreamName"] not in base:
                target = s["logStreamName"]
                break
        if target is None:
            time.sleep(2)
    print(f"locked to one run: {target}\n" + "=" * 70)
    stream_names = [target]
    start = int(time.time() * 1000) - 120000

print(f"tailing {log_group}{' [single run]' if stream_names else ''}  (Ctrl-C to stop)")
seen = set()
while True:
    try:
        kw = {"logGroupName": log_group, "startTime": start}
        if stream_names:
            kw["logStreamNames"] = stream_names
        while True:
            r = logs.filter_log_events(**kw)
            for e in r.get("events", []):
                if e["eventId"] in seen:
                    continue
                seen.add(e["eventId"])
                start = max(start, e["timestamp"])
                print(e["message"].rstrip())
            if not r.get("nextToken"):
                break
            kw["nextToken"] = r["nextToken"]
        time.sleep(3)
    except KeyboardInterrupt:
        break
