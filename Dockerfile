# =============================================================================
# Lugh Django Backend — Multi-stage Production Dockerfile
# =============================================================================

# ── Stage 1: Python dependencies ─────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: Production image ─────────────────────────────────────────────────
FROM python:3.11-slim AS production

WORKDIR /app

# Runtime dependencies only. postgresql-client provides pg_dump/pg_restore
# for backup_db (find_device/management/commands/backup_db.py) — libpq5
# alone (just the client library) doesn't include those CLI tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    postgresql-client \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Copy installed Python packages from builder
COPY --from=builder /install /usr/local

# Non-root application user — UID/GID pinned (not auto-assigned) so it's
# stable across rebuilds. Matters because docker-compose bind-mounts host
# directories over /app/staticfiles and /app/media in production; those
# host directories need to be chowned to this same UID/GID (see
# DEPLOYMENT_MANUAL.md), which only works if the UID doesn't drift between
# image builds.
RUN groupadd -r -g 1000 django && useradd -r -u 1000 -g django django
RUN mkdir -p /app/staticfiles /app/media && chown -R django:django /app

# Copy application source
COPY --chown=django:django . .

USER django

# Gunicorn must use 1 worker due to in-memory DeviceRegistry.
# Do NOT increase workers without first moving registry state to Redis/DB.
ENV WEB_CONCURRENCY=1
ENV DJANGO_SETTINGS_MODULE=PLC_Project.settings

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/')" || exit 1

CMD ["gunicorn", "--config", "gunicorn.conf.py", "PLC_Project.wsgi:application"]
