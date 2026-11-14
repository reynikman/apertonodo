from __future__ import annotations

import os

import uvicorn

from app.log_config import LOGGING_CONFIG


def main() -> None:
    uvicorn.run(
        "app.main:app",
        host=os.environ.get("BIND_HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8088")),
        log_config=LOGGING_CONFIG,
        access_log=True,
    )


if __name__ == "__main__":
    main()
