"""AgentCore runtime entrypoint for the customer-facing orchestrator agent."""
from bedrock_agentcore.runtime import BedrockAgentCoreApp

import audit
import orchestrator

app = BedrockAgentCoreApp()


@app.entrypoint
def invoke(payload):
    audit.TRANSCRIPT.clear()
    agent = orchestrator.build(payload.get("model_id"))
    msg = agent(payload["query"]).message  # {'role','content':[...blocks...]}: keep only the spoken text
    answer = "".join(b["text"] for b in msg.get("content", []) if "text" in b).strip()
    return {"answer": answer, "transcript": list(audit.TRANSCRIPT)}


if __name__ == "__main__":
    app.run()
