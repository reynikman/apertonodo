from __future__ import annotations

import copy
import re
from typing import Any

from uvicorn.logging import AccessFormatter

# The stream token is a one-hour audio access pass. In the access log it used to
# appear in full and went to the log collector: anyone reading logs could listen to another
# user's session. Instead, an ellipsis is shown; which lines belong to the same song
# can be seen via the `stream <number>` line from the application logger, where number
# is the prefix of the token hash.
_TOKEN_PATHS = re.compile(r"^(/v1/stream/|/v1/playback/)[^/?]+")


class SafeAccessFormatter(AccessFormatter):
    """Uvicorn access lines without query string, client address or token."""

    def formatMessage(self, record: Any) -> str:
        recordcopy = copy.copy(record)
        args = recordcopy.args
        if isinstance(args, tuple) and len(args) >= 5:
            _client, method, full_path, http_version, status_code = args[:5]
            path = _TOKEN_PATHS.sub(r"\1…", str(full_path).split("?", 1)[0])
            recordcopy.args = ("-", method, path, http_version, status_code)
        return super().formatMessage(recordcopy)
