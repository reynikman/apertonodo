from __future__ import annotations

import logging
import os
from collections.abc import Callable, Coroutine
from typing import Any

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field
from sentry_sdk import Client
from sentry_sdk.transport import HttpTransport
from urllib3.exceptions import HTTPError

from app.guard import ApiKeyGuard

logger = logging.getLogger("apertonodo")
MAX_BODY_BYTES = 256 * 1024
REPORT_FIELDS = frozenset({"kind", "screen", "app_version", "os", "frames", "function", "file", "line"})


class ReportFrame(BaseModel):
    model_config = ConfigDict(extra="forbid")

    function: str = Field(pattern=r"^[A-Za-z0-9_.<> $-]{1,200}$", max_length=200)
    file: str = Field(pattern=r"^(package:|dart:)[A-Za-z0-9_./-]{1,200}$", max_length=208)
    line: int = Field(ge=0, strict=True)


class AppReport(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: str = Field(pattern=r"^[a-z][a-z0-9_.-]{0,63}$", max_length=64)
    screen: str = Field(pattern=r"^[a-z][a-z0-9_.-]{0,63}$", max_length=64)
    app_version: str = Field(pattern=r"^[0-9A-Za-z.+-]{1,32}$", max_length=32)
    os: str = Field(pattern=r"^[0-9A-Za-z .+-]{1,32}$", max_length=32)
    frames: list[ReportFrame] = Field(max_length=100)


class ReportRoute(APIRoute):
    def get_route_handler(self) -> Callable[[Request], Coroutine[Any, Any, Response]]:
        handler = super().get_route_handler()

        async def private_errors(request: Request) -> Response:
            chunks = []
            size = 0
            async for chunk in request.stream():
                size += len(chunk)
                if size > MAX_BODY_BYTES:
                    return JSONResponse({"detail": "Report too large"}, status_code=413)
                chunks.append(chunk)
            request._body = b"".join(chunks)
            try:
                return await handler(request)
            except RequestValidationError as exc:
                # Even an extra field's name can contain private text. Never
                # return input, ctx, or a location supplied by the caller.
                errors = [
                    {
                        "type": error["type"],
                        "loc": [
                            part if isinstance(part, int) or part == "body" or part in REPORT_FIELDS else "field"
                            for part in error["loc"]
                        ],
                        "msg": error["msg"],
                    }
                    for error in exc.errors()
                ]
                return JSONResponse({"detail": errors}, status_code=422)

        return private_errors


class ReportTransport(HttpTransport):
    TIMEOUT = 1

    def _get_pool_options(self) -> dict[str, Any]:
        options = super()._get_pool_options()
        options["retries"] = 0
        return options

    def _request(self, *args: Any, **kwargs: Any) -> Any:
        try:
            response = super()._request(*args, **kwargs)
            if response.status >= 400:
                response.close()
                raise HTTPError("Report collector refused the event")
            return response
        except Exception as exc:
            logger.warning("report failed %s", type(exc).__name__)
            raise


def _only_report_fields(event: Any, hint: Any) -> Any:
    return {
        key: event[key]
        for key in ("event_id", "timestamp", "level", "message", "tags", "release", "platform", "exception")
        if key in event
    }


def install_app_reports(app: FastAPI, api_key: str | None = None) -> None:
    # create_app(api_key=None) leaves other fixture routes unlocked. Reports
    # always use the same key check; UserGuard validates Bearer before routing.
    guard = ApiKeyGuard(app, key=api_key if api_key is not None else os.environ.get("MUSIC_API_KEY", ""))

    def locked(request: Request) -> None:
        if not guard._allowed(dict(request.scope)):
            raise HTTPException(status_code=401, detail="Unauthorized")

    router = APIRouter(route_class=ReportRoute, dependencies=[Depends(locked)])

    @router.post("/v1/reports", status_code=202)
    def report(body: AppReport) -> JSONResponse:
        dsn = os.environ.get("GLITCHTIP_MOBILE_DSN", "").strip()
        if not dsn:
            return JSONResponse({"status": "reports_off"}, status_code=503)
        logger.info("report %s", body.kind)
        try:
            # No global client, Scope, automatic integrations or request data.
            # Closing flushes for at most one second, even if GlitchTip is down.
            with Client(
                dsn=dsn,
                transport=ReportTransport,
                default_integrations=False,
                auto_enabling_integrations=False,
                send_default_pii=False,
                include_local_variables=False,
                max_request_body_size="never",
                max_breadcrumbs=0,
                traces_sample_rate=0,
                enable_backpressure_handling=False,
                send_client_reports=False,
                transport_queue_size=1,
                shutdown_timeout=1.0,
                before_send=_only_report_fields,
            ) as client:
                # SDK's Python typing only lists platform="python", but this
                # is an event from the Dart application, not the server.
                event: Any = {
                    "level": "error",
                    "message": body.kind,
                    "tags": {"screen": body.screen, "os": body.os},
                    "release": body.app_version,
                    "platform": "dart",
                    "exception": {"values": [{
                        "type": body.kind,
                        "stacktrace": {"frames": [
                            {"function": frame.function, "filename": frame.file, "lineno": frame.line}
                            for frame in body.frames
                        ]},
                    }]},
                }
                client.capture_event(event)
        except Exception as exc:
            logger.warning("report failed %s", type(exc).__name__)
        return JSONResponse({"status": "accepted"}, status_code=202)

    app.include_router(router)
