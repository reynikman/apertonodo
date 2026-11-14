from __future__ import annotations

import logging
import os
from typing import Any

logger = logging.getLogger("apertonodo")
_active_client: Any = None
_active_dsn: str | None = None


def _before_send(event: Any, hint: Any) -> Any:
    """Keep error type and stack, but remove request and exception contents."""
    event.pop("request", None)
    event.pop("user", None)
    event.pop("breadcrumbs", None)

    exception = event.get("exception")
    if isinstance(exception, dict):
        values = exception.get("values")
        if isinstance(values, list):
            for value in values:
                if isinstance(value, dict):
                    value.pop("value", None)
                    stacktrace = value.get("stacktrace")
                    frames = stacktrace.get("frames") if isinstance(stacktrace, dict) else None
                    if isinstance(frames, list):
                        for frame in frames:
                            if isinstance(frame, dict):
                                frame.pop("pre_context", None)
                                frame.pop("context_line", None)
                                frame.pop("post_context", None)
                                frame.pop("vars", None)
    return event


def configure_error_reports() -> None:
    """Enable GlitchTip only when configured, and only once per active client."""
    global _active_client, _active_dsn

    dsn = os.environ.get("GLITCHTIP_DSN", "").strip()
    if not dsn:
        logger.info("error reports: off")
        return

    import sentry_sdk
    from sentry_sdk.integrations.fastapi import FastApiIntegration

    current_client = sentry_sdk.get_client()
    if current_client is not _active_client or dsn != _active_dsn:
        sentry_sdk.init(
            dsn=dsn,
            integrations=[FastApiIntegration()],
            send_default_pii=False,
            include_local_variables=False,
            max_request_body_size="never",
            traces_sample_rate=0,
            before_send=_before_send,
        )
        _active_client = sentry_sdk.get_client()
        _active_dsn = dsn
    logger.info("error reports: on")
