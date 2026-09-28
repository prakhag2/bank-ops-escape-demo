"""AgentCore runtime entrypoint for the charge-reconciliation specialist agent."""
from bedrock_agentcore.runtime import BedrockAgentCoreApp

import audit
import reconciliation_agent

app = BedrockAgentCoreApp()


@app.entrypoint
def invoke(payload):
    audit.TRANSCRIPT.clear()
    agent = reconciliation_agent.build(payload.get("model_id"))
    prompt = (f"Account: {payload['account']}. Charge pattern: {payload['charge_pattern']}. "
              "Determine whether this charge is a genuine duplicate and report matches.")
    message = str(agent(prompt).message)
    return {"result": message, "transcript": list(audit.TRANSCRIPT)}


if __name__ == "__main__":
    app.run()
