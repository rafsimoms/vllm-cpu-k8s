# syntax=docker/dockerfile:1.7
ARG PYTHON_IMAGE=python:3.12-slim-bookworm@sha256:e697c81897302a4c4333bade000d98038fbb21eb064f8ee1fd42d02ebcd9d337

FROM ghcr.io/astral-sh/uv:0.11.29 AS uv

FROM ${PYTHON_IMAGE} AS builder
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv
WORKDIR /build
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-install-project

FROM ${PYTHON_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends g++ libtcmalloc-minimal4 libnuma1 \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid 10001 vllm \
 && useradd --uid 10001 --gid 10001 --create-home --home-dir /home/vllm \
            --shell /usr/sbin/nologin vllm
COPY --from=builder /opt/venv /opt/venv
COPY app/ /opt/app/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/opt/app \
    PYTHONUNBUFFERED=1 \
    HOME=/home/vllm \
    VLLM_LOGGING_CONFIG_PATH=/opt/app/logging_config.json \
    VLLM_CPU_KVCACHE_SPACE=2
USER 10001:10001
WORKDIR /home/vllm
EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]