FROM nvidia/cuda:12.8.0-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev \
      git ca-certificates curl build-essential ffmpeg libegl1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.8.14 /uv /uvx /usr/local/bin/

# Reuse Ubuntu's built-in uid-1000 user, renamed for clarity
RUN usermod -l astra -d /home/astra -m ubuntu && groupmod -n astra ubuntu \
 && mkdir -p /workspace /data && chown -R astra:astra /workspace /data
USER astra

ENV UV_PROJECT_ENVIRONMENT=/workspace/.venv UV_LINK_MODE=copy UV_PYTHON=/usr/bin/python3.12
WORKDIR /workspace/Isaac-GR00T

COPY --chown=astra:astra third_party/Isaac-GR00T/pyproject.toml third_party/Isaac-GR00T/uv.lock ./
COPY --chown=astra:astra third_party/Isaac-GR00T/scripts/deployment/dgpu/wheels/ ./scripts/deployment/dgpu/wheels/
RUN uv sync --frozen --no-install-project

COPY --chown=astra:astra third_party/Isaac-GR00T/ ./
RUN uv sync --frozen

COPY --chown=astra:astra config/gr00t/galbot_config.py /workspace/galbot/galbot_config.py
COPY docker/gr00t-entrypoint.sh /usr/local/bin/entrypoint.sh

ENV PATH=/workspace/.venv/bin:$PATH \
    HF_HOME=/data/hf_cache \
    PYTHONPATH=/workspace/galbot
ENTRYPOINT ["entrypoint.sh"]
CMD ["--help"]
