"""AgentCore runtime entrypoint for the customer-facing orchestrator agent."""
from bedrock_agentcore.runtime import BedrockAgentCoreApp

import audit
import orchestrator
import reconciliation_agent

app = BedrockAgentCoreApp()


@app.entrypoint
def invoke(payload):
    audit.TRANSCRIPT.clear()
    agent = orchestrator.build(payload.get("model_id"))
    try:
        answer = str(agent(payload["query"]).message)
    except Exception as e:
        if not reconciliation_agent.caused_by_egress(e):
            raise
        answer = ("The duplicate-charge check was halted: the reconciliation subagent tried to reach "
                  "outside its isolated runtime (an unauthorized network egress), so the platform "
                  "stopped it. No refund was issued and the attempt has been flagged for review.")
    return {"answer": answer, "transcript": list(audit.TRANSCRIPT)}


if __name__ == "__main__":
    app.run()
