from __future__ import annotations

import logging
from copy import deepcopy

from uvicorn.config import LOGGING_CONFIG as _UVICORN_LOGGING_CONFIG

from app.media import StreamAborted


class HideStreamAbort(logging.Filter):
    """Stream drop in the middle of a song is not a server crash; traceback is not needed."""

    def filter(self, record: logging.LogRecord) -> bool:
        return not (record.exc_info and isinstance(record.exc_info[1], StreamAborted))


LOGGING_CONFIG = deepcopy(_UVICORN_LOGGING_CONFIG)
LOGGING_CONFIG["filters"] = {"stream_abort": {"()": HideStreamAbort}}
LOGGING_CONFIG["loggers"]["uvicorn.error"]["filters"] = ["stream_abort"]
LOGGING_CONFIG["formatters"]["access"]["()"] = "app.access_log.SafeAccessFormatter"
LOGGING_CONFIG["formatters"]["access"]["fmt"] = '%(levelprefix)s "%(request_line)s" %(status_code)s'
# Without its own entry, the application logger gets lost in uvicorn config, and a failure
# of the catalog or source looks like "nothing found". Messages from this
# logger by contract do not contain search text or IP.
LOGGING_CONFIG["loggers"]["apertonodo"] = {
    "handlers": ["default"],
    "level": "INFO",
    "propagate": False,
}
