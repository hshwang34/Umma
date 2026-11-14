# Umma API + worker image (brief 010). One image, two Fly process groups (see /fly.toml).
#
# Build context is the REPO ROOT, not backend/: the app reads ../fixtures at runtime (the
# labelled demo answers used when an AI cap is hit, and the seed data).
#   docker build -f backend/Dockerfile -t umma-api .
FROM python:3.12-slim-bookworm AS build
COPY --from=ghcr.io/astral-sh/uv:0.11.9 /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /srv/umma/backend
# Dependencies first so code changes do not reinstall them. Runtime deps only, exactly as locked.
COPY backend/pyproject.toml backend/uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked --no-dev --no-install-project

FROM python:3.12-slim-bookworm
# ffmpeg/ffprobe: the worker probes creator video and cuts step clips (brief 008).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home --home-dir /home/umma umma
ENV PATH="/srv/umma/backend/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /srv/umma/backend
COPY --from=build /srv/umma/backend/.venv ./.venv
COPY backend/alembic.ini ./
COPY backend/app ./app
COPY fixtures /srv/umma/fixtures
USER umma
EXPOSE 8080
# Fly overrides this per process group; it is also the default for `docker run`.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
