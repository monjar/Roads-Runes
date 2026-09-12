"""Optional LLM access for narrative text and natural-language route requests.

The LLM only ever produces *text* or *structured preferences*. It never
produces coordinates that reach navigation and never decides route safety
(spec §20, §31). When no provider is configured `NullLLM` is used and callers
fall back to deterministic templates.
"""

from __future__ import annotations

import json
from typing import Any, Protocol

from app.core.config import Settings
from app.core.logging import get_logger

log = get_logger(__name__)


class LLMClient(Protocol):
    enabled: bool

    async def complete_json(self, system: str, user: str, schema_hint: str) -> dict[str, Any] | None: ...


class NullLLM:
    enabled = False

    async def complete_json(self, system: str, user: str, schema_hint: str) -> dict[str, Any] | None:
        return None


class AnthropicLLM:
    """Claude Messages API via the official SDK (imported lazily so the
    dependency is optional in environments that never enable the provider)."""

    enabled = True

    def __init__(self, api_key: str, model: str) -> None:
        self._api_key = api_key
        self._model = model
        self._client = None
        # Reasoning effort is an Opus/Sonnet 5 control; Haiku rejects the parameter.
        # Rather than keep a list of which model has it, ask once and remember.
        self._effort: str | None = "low"

    def _get_client(self):
        if self._client is None:
            from anthropic import AsyncAnthropic  # type: ignore[import-not-found]

            self._client = AsyncAnthropic(api_key=self._api_key)
        return self._client

    async def complete_json(self, system: str, user: str, schema_hint: str) -> dict[str, Any] | None:
        for _ in range(2):
            try:
                client = self._get_client()
                response = await client.messages.create(
                    model=self._model,
                    max_tokens=2048,
                    system=system + "\n\nRespond with a single JSON object only. Schema: " + schema_hint,
                    messages=[{"role": "user", "content": user}],
                    **({"output_config": {"effort": self._effort}} if self._effort else {}),
                )
            except Exception as exc:  # noqa: BLE001 - LLM is optional; never break the request path
                if self._effort and "effort" in str(exc):
                    self._effort = None
                    continue
                log.warning("llm_call_failed", model=self._model, error=str(exc))
                return None
            try:
                if getattr(response, "stop_reason", None) == "refusal":
                    return None
                text = "".join(block.text for block in response.content if getattr(block, "type", "") == "text")
                start, end = text.find("{"), text.rfind("}")
                if start == -1 or end == -1:
                    return None
                return json.loads(text[start : end + 1])
            except Exception as exc:  # noqa: BLE001
                log.warning("llm_reply_unreadable", model=self._model, error=str(exc))
                return None
        return None


def build_llm(settings: Settings) -> LLMClient:
    if settings.llm_provider == "anthropic" and settings.anthropic_api_key:
        return AnthropicLLM(settings.anthropic_api_key, settings.anthropic_model)
    return NullLLM()
