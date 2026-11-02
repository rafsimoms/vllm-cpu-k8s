# syntax=docker/dockerfile:1.7
ARG PYTHON_IMAGE=python:3.12-slim-bookworm@sha256:e697c81897302a4c4333bade000d98038fbb21eb064f8ee1fd42d02ebcd9d337

FROM ghcr.io/astral-sh/uv:0.11.29 AS uv

FROM ${PYTHON_IMAGE} AS builder
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
COPY requirements.txt /tmp/requirements.txt
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv --python /usr/local/bin/python3.12 /opt/venv && \
    VIRTUAL_ENV=/opt/venv uv pip sync --require-hashes /tmp/requirements.txt

FROM ${PYTHON_IMAGE}
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=builder /opt/venv /opt/venv
COPY --chmod=0755 download_model.py /usr/local/bin/download_model.py
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/tmp/hf
USER 10001:10001
ENTRYPOINT ["python", "/usr/local/bin/download_model.py"]