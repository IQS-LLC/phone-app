#!/usr/bin/env bash
# Single-process Lugh backend with no Docker/Celery/Redis — the stopgap for a
# Windows host where WSL2/Docker can't run. Uses SQLite (db.sqlite3), reads
# PLC settings from .env, and runs the embedded scheduler in place of Celery
# Beat (see find_device/embedded_scheduler.py).
#
# Usage (Git Bash, from anywhere):  phone-app/scripts/run_native_server.sh
set -euo pipefail
cd "$(dirname "$0")/.."

env_val() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }

export DJANGO_SETTINGS_MODULE=PLC_Project.settings
export SECRET_KEY="$(env_val SECRET_KEY)"
export DEBUG=True
export PLC_MOCK="$(env_val PLC_MOCK)"
export PLC_NETID="$(env_val PLC_NETID)" PLC_IP="$(env_val PLC_IP)"
export LOCAL_AMS_NET_ID="$(env_val LOCAL_AMS_NET_ID)" LOCAL_AMS_HOST="$(env_val LOCAL_AMS_HOST)"
export PLC_ROUTE_USERNAME="$(env_val PLC_ROUTE_USERNAME)" PLC_ROUTE_PASSWORD="$(env_val PLC_ROUTE_PASSWORD)"
export BUILDING_TIME_ZONE="$(env_val BUILDING_TIME_ZONE)"
# Leading dot = any subdomain: Cloudflare quick-tunnel hostnames change on
# every tunnel restart, and that must never require a server restart.
export EXTRA_ALLOWED_HOSTS="$(env_val EXTRA_ALLOWED_HOSTS),192.168.5.162,10.0.2.2,localhost,127.0.0.1,.trycloudflare.com"
# CORS_ALLOWED_ORIGINS deliberately left unset here: with DEBUG=True this
# server already allows all CORS origins (see settings.py's
# CORS_ALLOW_ALL_ORIGINS), which matters for the web build and is more
# robust than an explicit tunnel-hostname list that goes stale the next
# time a quick tunnel restarts with a new hostname.

./.venv/Scripts/python.exe manage.py migrate --noinput
# Scheduler flag scoped to the server process only — exported globally, the
# migrate step above would also start it and run a tick from a throwaway process.
LUGH_EMBEDDED_SCHEDULER=1 exec ./.venv/Scripts/python.exe manage.py runserver 0.0.0.0:8000 --noreload
