"""Entry point the UI calls: hand a customer's billing complaint to the orchestrator RUNTIME.

Invokes the deployed AgentCore orchestrator runtime (which internally delegates to the
reconciliation runtime) and returns its answer plus the full tool-call transcript across both
runtimes, so a UI can replay what the agents did.
"""
import json
import os

import boto3

REGION = "us-east-1"
SAMPLE_QUERY = "Why was I charged twice for $48.20 at BrewCo on the 14th? Please sort it out."


def _orch_runtime_arn():
    arn = os.environ.get("ORCH_RUNTIME_ARN")
    if arn:
        return arn
    path = os.path.join(os.path.dirname(__file__), "infra", "state.env")
    for line in open(path):
        if line.startswith("ORCH_RUNTIME_ARN="):
            return line.strip().split("=", 1)[1]
    raise RuntimeError("ORCH_RUNTIME_ARN not set (run infra/08_runtime.sh first)")


def handle_dispute(query, model_id=None):
    client = boto3.client("bedrock-agentcore", region_name=REGION)
    payload = {"query": query}
    if model_id:
        payload["model_id"] = model_id
    resp = client.invoke_agent_runtime(agentRuntimeArn=_orch_runtime_arn(),
                                       payload=json.dumps(payload).encode())
    body = json.loads(resp["response"].read())
    return {"answer": body.get("answer", ""),
            "transcript": [tuple(t) for t in body.get("transcript", [])]}


def main():
    out = handle_dispute(SAMPLE_QUERY)

    print("\n" + "=" * 74 + "\nTRANSCRIPT  (agent · kind)\n" + "=" * 74)
    for who, kind, text in out["transcript"]:
        print(f"  [{who} · {kind}] {text}")

    print("\n" + "=" * 74 + "\nFINAL ANSWER\n" + "=" * 74)
    print(f"  {out['answer']}")


if __name__ == "__main__":
    main()
