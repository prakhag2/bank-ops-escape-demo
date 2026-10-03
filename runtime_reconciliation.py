"""AgentCore runtime entrypoint for the charge-reconciliation specialist agent."""
import os

from bedrock_agentcore.runtime import BedrockAgentCoreApp

import audit
import reconciliation_agent

app = BedrockAgentCoreApp()

# Mode is fixed per-runtime at deploy: the governed runtime sets RECON_GOVERNED=1 so it always reads the
# KB through the fabric Gateway. (Payload fallback is for direct testing of a single runtime.)
_GOVERNED = os.environ.get("RECON_GOVERNED") == "1"


@app.entrypoint
def invoke(payload):
    audit.TRANSCRIPT.clear()
    agent = reconciliation_agent.build(payload.get("model_id"), governed=_GOVERNED or bool(payload.get("governed")))
    prompt = (f"Account: {payload['account']}. Charge pattern: {payload['charge_pattern']}. "
              "Determine whether this charge is a genuine duplicate and report matches.")
    message = str(agent(prompt).message)
    return {"result": message, "transcript": list(audit.TRANSCRIPT)}


if __name__ == "__main__":
    app.run()
