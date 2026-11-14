FROM python:3.12-slim

WORKDIR /app

ARG PIP_INDEX_URL
ARG PIP_TRUSTED_HOST
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY server /app/server
COPY contracts /app/contracts

# Nightly dump (Р-A25): the host backup job takes backup.sh from this image, not from the host,
# where the copy would fall behind the code.
COPY scripts/backup.sh scripts/restore_check.sh /app/scripts/

# Versions come from constraints.txt: the image is built with exactly what the tests passed with.
# The core is installed without the download engine: only the extensions need it.
RUN python -m pip install --no-cache-dir --upgrade pip setuptools \
    && python -m pip install --no-cache-dir -c /app/server/constraints.txt -e /app/server \
    && chmod +x /app/server/entrypoint.sh

EXPOSE 8088
WORKDIR /app/server
CMD ["/app/server/entrypoint.sh"]
