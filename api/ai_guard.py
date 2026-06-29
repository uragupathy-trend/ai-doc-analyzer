import json
import logging
import requests
from config import V1_API_KEY, AI_GUARD_ENDPOINT, AI_GUARD_APP_NAME

logger = logging.getLogger(__name__)


class AIGuardClient:
    def __init__(self):
        self.endpoint = AI_GUARD_ENDPOINT
        self.headers = {
            "Authorization": f"Bearer {V1_API_KEY}",
            "Content-Type": "application/json",
            "TMV1-Application-Name": AI_GUARD_APP_NAME,
            "Prefer": "return=representation",
        }

    def scan_prompt(self, messages: list) -> dict:
        """Scan prompt messages before sending to Bedrock."""
        payload = {
            "model": "anthropic.claude-3-5-sonnet-20241022-v2:0",
            "messages": messages,
        }
        return self._call_guard("OpenAIChatCompletionRequestV1", payload)

    def scan_response(self, response_text: str, model_id: str) -> dict:
        """Scan LLM response before returning to user."""
        payload = {
            "id": "bedrock-response",
            "object": "chat.completion",
            "created": 0,
            "model": model_id,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": response_text, "refusal": None},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
        return self._call_guard("OpenAIChatCompletionResponseV1", payload)

    def _call_guard(self, request_type: str, payload: dict) -> dict:
        headers = {**self.headers, "TMV1-Request-Type": request_type}
        try:
            resp = requests.post(self.endpoint, headers=headers, json=payload, timeout=10)
            resp.raise_for_status()
            return resp.json()
        except requests.RequestException as e:
            logger.error("AI Guard call failed: %s", e)
            # Fail open with a warning — block in production
            return {"action": "Allow", "reasons": [], "error": str(e)}


def is_blocked(guard_result: dict) -> bool:
    return guard_result.get("action", "Allow") == "Block"
