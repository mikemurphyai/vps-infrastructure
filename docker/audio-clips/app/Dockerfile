FROM ghcr.io/astral-sh/uv:0.12.5 AS uv
FROM python:3.12.11-slim-bookworm
COPY --from=uv /uv /usr/local/bin/uv
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home appuser \
    && mkdir /storage && chown 10001:10001 /storage
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev
COPY app.py shorts.py hosting.py access_auth.py ./
COPY .streamlit/ ./.streamlit/
ENV PATH="/app/.venv/bin:$PATH" CLIPS_STORAGE=/storage
USER 10001:10001
EXPOSE 8517
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8517/_stcore/health', timeout=3)"]
CMD ["streamlit", "run", "app.py", "--server.address=0.0.0.0", "--server.port=8517", "--server.maxUploadSize=90", "--server.headless=true"]
