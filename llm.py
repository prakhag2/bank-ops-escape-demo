"""Shared Bedrock model factory."""
from strands.models import BedrockModel

ORCHESTRATOR_MODEL = "us.anthropic.claude-opus-4-8"
DEPUTY_MODEL = "us.anthropic.claude-opus-4-8"


def model(model_id):
    # Non-Anthropic Bedrock models don't support tool use in streaming mode and reject the
    # Anthropic-only adaptive-thinking field, so use plain converse for them.
    anthropic = "anthropic" in model_id
    extra = {"thinking": {"type": "adaptive"}} if anthropic else {}
    return BedrockModel(model_id=model_id, region_name="us-east-1", max_tokens=8000,
                        streaming=anthropic, additional_request_fields=extra)
