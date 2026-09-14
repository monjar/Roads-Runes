"""Claude access for narrative text and for reading a rider's route request.

The model only ever produces *text* or *structured preferences*. It never
produces coordinates that reach navigation and never decides route safety
(spec §20, §31): it returns the place *name* it read, and `app/routing/geocode.py`
turns that into a point, so a hallucinated coordinate has nowhere to go.

`extract` is the one used for reading requests. It asks for a schema-valid
object through `output_config.format`, which the API enforces, and falls back to
describing the schema in the system prompt for a model or endpoint that does not
take the parameter. `complete_json` is the older free-form call, still used for
quest narrative where the shape is loose and a miss costs a flavour line.

With no provider configured `NullLLM` is used: narrative falls back to
deterministic templates, and a typed route request is answered honestly rather
than guessed at.
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

    async def extract(self, system: str, user: str, schema: dict[str, Any]) -> dict[str, Any] | None: ...


class NullLLM:
    enabled = False

    async def complete_json(self, system: str, user: str, schema_hint: str) -> dict[str, Any] | None:
        return None

    async def extract(self, system: str, user: str, schema: dict[str, Any]) -> dict[str, Any] | None:
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
        # Same for schema-enforced output: used when the endpoint takes it, dropped
        # for good when it does not, so no request pays for the discovery twice.
        self._structured = True

    def _get_client(self):
        if self._client is None:
            from anthropic import AsyncAnthropic  # type: ignore[import-not-found]

            self._client = AsyncAnthropic(api_key=self._api_key)
        return self._client

    async def _call(self, system: str, user: str, output_config: dict[str, Any]) -> str | None:
        """One request. Returns the reply text, or None if there is nothing to read."""
        response = await self._get_client().messages.create(
            model=self._model,
            max_tokens=2048,
            system=system,
            messages=[{"role": "user", "content": user}],
            **({"output_config": output_config} if output_config else {}),
        )
        if getattr(response, "stop_reason", None) == "refusal":
            log.warning("llm_refused", model=self._model)
            return None
        return "".join(block.text for block in response.content if getattr(block, "type", "") == "text")

    def _output_config(self, schema: dict[str, Any] | None) -> dict[str, Any]:
        config: dict[str, Any] = {}
        if self._effort:
            config["effort"] = self._effort
        if schema is not None and self._structured:
            config["format"] = {"type": "json_schema", "schema": schema}
        return config

    def _unsupported(self, exc: Exception) -> bool:
        """Did the endpoint reject a parameter rather than the request?

        Both controls are recent, and the model is configurable, so a deployment
        can point at something that has neither. One rejection each is the cost of
        finding out; after that the client stops sending it.
        """
        message = str(exc)
        if self._effort and "effort" in message:
            self._effort = None
            return True
        if self._structured and ("output_config" in message or "format" in message or "json_schema" in message):
            self._structured = False
            return True
        return False

    async def extract(self, system: str, user: str, schema: dict[str, Any]) -> dict[str, Any] | None:
        """A JSON object matching `schema`, or None if the model could not give one."""
        described = system
        for _ in range(3):
            if not self._structured:
                described = system + "\n\nRespond with a single JSON object only, matching this JSON Schema:\n"
                described += json.dumps(schema)
            try:
                text = await self._call(described, user, self._output_config(schema))
            except Exception as exc:  # noqa: BLE001 - a request must survive a bad model call
                if self._unsupported(exc):
                    continue
                log.warning("llm_call_failed", model=self._model, error=str(exc))
                return None
            return _first_object(text, model=self._model)
        return None

    async def complete_json(self, system: str, user: str, schema_hint: str) -> dict[str, Any] | None:
        described = system + "\n\nRespond with a single JSON object only. Schema: " + schema_hint
        for _ in range(2):
            try:
                text = await self._call(described, user, self._output_config(None))
            except Exception as exc:  # noqa: BLE001
                if self._unsupported(exc):
                    continue
                log.warning("llm_call_failed", model=self._model, error=str(exc))
                return None
            return _first_object(text, model=self._model)
        return None


def _first_object(text: str | None, model: str) -> dict[str, Any] | None:
    """The JSON object in a reply. Schema-enforced replies are already one; a
    prompt-described reply may carry a sentence around it."""
    if not text:
        return None
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end == -1:
        return None
    try:
        parsed = json.loads(text[start : end + 1])
    except ValueError as exc:
        log.warning("llm_reply_unreadable", model=model, error=str(exc))
        return None
    return parsed if isinstance(parsed, dict) else None


def build_llm(settings: Settings) -> LLMClient:
    if settings.llm_provider == "anthropic" and settings.anthropic_api_key:
        return AnthropicLLM(settings.anthropic_api_key, settings.anthropic_model)
    return NullLLM()
