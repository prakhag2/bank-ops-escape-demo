"""Audit logging for the bank agents: records each model message and tool call/result into a
shared transcript and streams it to stdout so a run can be followed live in CloudWatch."""
import json

from strands.hooks import MessageAddedEvent, HookProvider

TRANSCRIPT = []  # chronological (agent_name, kind, text) for the current run


def _emit(agent_name, kind, text):
    TRANSCRIPT.append((agent_name, kind, text))
    print(f"[{agent_name} · {kind}] {text}", flush=True)


def _payload(result):
    for block in (result or {}).get("content", []):
        if "json" in block:
            return block["json"]
        if "text" in block:
            return block["text"]
    return None


class AuditLogger(HookProvider):
    def register_hooks(self, registry, **kwargs):
        registry.add_callback(MessageAddedEvent, self._on_message)

    def _on_message(self, event):
        agent_name = getattr(event.agent, "name", "agent")
        msg = event.message if isinstance(event.message, dict) else {}
        role = msg.get("role", "?")
        for block in msg.get("content", []):
            if not isinstance(block, dict):
                continue
            if "reasoningContent" in block:
                rc = block["reasoningContent"]
                text = (rc.get("reasoningText") or {}).get("text")
                if text:
                    _emit(agent_name, "thinking", text.strip())
            elif "text" in block:
                _emit(agent_name, role, block["text"].strip())
            elif "toolUse" in block:
                tu = block["toolUse"]
                # lead with the tool-use id (tab-separated) so the result can pair back to THIS call, not by position
                _emit(agent_name, "tool_call", f"{tu.get('toolUseId', '')}\t{tu.get('name')} {json.dumps(tu.get('input', {}))}")
            elif "toolResult" in block:
                tr = block["toolResult"]
                _emit(agent_name, "tool_result", f"{tr.get('toolUseId', '')}\t{str(_payload(tr))[:800]}")
