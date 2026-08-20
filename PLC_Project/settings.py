"""
Lumina PLC Backend — Django Settings
Production-hardened with structured logging, rate limiting, and security controls.
All secrets are read from environment variables.
"""
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

# ── Security ──────────────────────────────────────────────────────────────────

_INSECURE_DEFAULT_KEY = "django-insecure-change-me-in-production-use-env-var"

# In production: set SECRET_KEY env var to a long random string.
SECRET_KEY = os.getenv("SECRET_KEY", _INSECURE_DEFAULT_KEY)

DEBUG = os.getenv("DEBUG", "True").lower() == "true"

if not DEBUG and SECRET_KEY == _INSECURE_DEFAULT_KEY:
    raise RuntimeError(
        "Refusing to start with DEBUG=False and no SECRET_KEY set. "
        "Set the SECRET_KEY environment variable to a long random string "
        "before deploying (e.g. `python -c \"import secrets; "
        "print(secrets.token_urlsafe(50))\"`)."
    )

ALLOWED_HOSTS = [
    "localhost",
    "127.0.0.1",
    "0.0.0.0",
    "10.0.2.2",        # Android emulator's alias for the host machine
    "192.168.0.158",   # LAN server IP (Django host)
    "192.168.0.161",   # TwinCAT/PLC machine IP (Apartment 16)
    *[h.strip() for h in os.getenv("EXTRA_ALLOWED_HOSTS", "").split(",") if h.strip()],
]

# ── Application ───────────────────────────────────────────────────────────────

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "rest_framework",
    "rest_framework_simplejwt",
    "rest_framework_simplejwt.token_blacklist",
    "corsheaders",
    "django_celery_beat",
    "find_device",
]

MIDDLEWARE = [
    # CORS must be first
    "corsheaders.middleware.CorsMiddleware",
    # Lumina middlewares
    "find_device.middleware.RateLimitMiddleware",
    "find_device.middleware.RequestLoggingMiddleware",
    # Django built-ins
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    # JWTAuthMiddleware must run AFTER AuthenticationMiddleware — Django's
    # built-in middleware unconditionally overwrites request.user with its
    # session-resolved (Anonymous) user, which would clobber the JWT-resolved
    # user if we ran before it.
    "find_device.middleware.JWTAuthMiddleware",
    "find_device.middleware.APIKeyMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "PLC_Project.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "PLC_Project.wsgi.application"

# ── Database ──────────────────────────────────────────────────────────────────

DATABASES = {
    "default": {
        "ENGINE": os.getenv("DB_ENGINE", "django.db.backends.sqlite3"),
        "NAME":   os.getenv("DB_NAME",   str(BASE_DIR / "db.sqlite3")),
        "USER":   os.getenv("DB_USER",   ""),
        "PASSWORD": os.getenv("DB_PASSWORD", ""),
        "HOST":   os.getenv("DB_HOST",   ""),
        "PORT":   os.getenv("DB_PORT",   ""),
        # Connection pooling and resilience
        "OPTIONS": {},
        "CONN_MAX_AGE": int(os.getenv("DB_CONN_MAX_AGE", "60")),
    }
}

# ── Auth ──────────────────────────────────────────────────────────────────────

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

# ── Internationalisation ──────────────────────────────────────────────────────

LANGUAGE_CODE = "en-us"
TIME_ZONE     = os.getenv("TIME_ZONE", "UTC")
USE_I18N      = True
USE_TZ        = True

# ── Static files ──────────────────────────────────────────────────────────────

STATIC_URL   = "/static/"
STATIC_ROOT  = BASE_DIR / "staticfiles"
MEDIA_URL    = "/media/"
MEDIA_ROOT   = BASE_DIR / "media"
STATICFILES_STORAGE = "whitenoise.storage.CompressedManifestStaticFilesStorage"

# ── CORS ──────────────────────────────────────────────────────────────────────
# Local/dev (DEBUG=True) allows all origins for convenience — the Flutter app
# talks to whatever LAN IP the user configures. In production (DEBUG=False),
# only the explicit origins in CORS_ALLOWED_ORIGINS are allowed.

_cors_origins = [o.strip() for o in os.getenv("CORS_ALLOWED_ORIGINS", "").split(",") if o.strip()]

CORS_ALLOW_ALL_ORIGINS = DEBUG and not _cors_origins
CORS_ALLOWED_ORIGINS   = _cors_origins
CORS_ALLOW_METHODS     = ["GET", "POST", "OPTIONS", "PATCH", "DELETE"]
CORS_ALLOW_HEADERS     = ["content-type", "x-api-key", "accept", "authorization"]

# ── Rate limiting (used by RateLimitMiddleware) ───────────────────────────────

RATE_LIMIT_REQUESTS       = int(os.getenv("RATE_LIMIT_REQUESTS", "200"))
RATE_LIMIT_WRITE_REQUESTS = int(os.getenv("RATE_LIMIT_WRITE_REQUESTS", "60"))
RATE_LIMIT_WINDOW         = int(os.getenv("RATE_LIMIT_WINDOW", "60"))

# ── Production security headers (HTTPS only) ──────────────────────────────────

if not DEBUG and os.getenv("HTTPS_ENABLED", "False").lower() == "true":
    SECURE_BROWSER_XSS_FILTER        = True
    SECURE_CONTENT_TYPE_NOSNIFF       = True
    SECURE_HSTS_INCLUDE_SUBDOMAINS    = True
    SECURE_HSTS_PRELOAD               = True
    SECURE_HSTS_SECONDS               = 31_536_000  # 1 year
    SESSION_COOKIE_SECURE             = True
    CSRF_COOKIE_SECURE                = True
    SECURE_SSL_REDIRECT               = True
    # Without this, Django has no way to know nginx (or Cloudflare in front
    # of it) already terminated TLS — every request arrives at gunicorn as
    # plain HTTP, so SECURE_SSL_REDIRECT sees "not HTTPS" and redirects,
    # forever. nginx.conf must set X-Forwarded-Proto for this to be correct.
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
    # Docker's own healthcheck hits gunicorn directly on localhost:8000,
    # bypassing nginx entirely — no X-Forwarded-Proto header there, so
    # SECURE_SSL_REDIRECT would 301 it to https on a port that only ever
    # speaks plain HTTP, hanging the single gunicorn worker until timeout.
    SECURE_REDIRECT_EXEMPT = [r"^health/?$"]

# ── Structured logging ────────────────────────────────────────────────────────

LOG_LEVEL = os.getenv("LOG_LEVEL", "DEBUG" if DEBUG else "INFO")

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "json": {
            "()": "django.utils.log.ServerFormatter",
            "format": "{levelname} {asctime} {name} {message}",
            "style":  "{",
        },
        "verbose": {
            "format": "{levelname} {asctime} [{name}] {message}",
            "style":  "{",
        },
        "simple": {
            "format": "{levelname} {message}",
            "style":  "{",
        },
    },
    "filters": {
        "require_debug_false": {"()": "django.utils.log.RequireDebugFalse"},
    },
    "handlers": {
        "console": {
            "class":     "logging.StreamHandler",
            "formatter": "verbose",
        },
        "error_file": {
            "class":     "logging.handlers.RotatingFileHandler",
            "filename":  str(BASE_DIR / "logs" / "errors.log"),
            "maxBytes":  10 * 1024 * 1024,  # 10 MB
            "backupCount": 5,
            "formatter": "verbose",
            "level":     "ERROR",
        },
    },
    "root": {
        "handlers": ["console"],
        "level":    LOG_LEVEL,
    },
    "loggers": {
        "lumina": {
            "handlers":  ["console"],
            "level":     LOG_LEVEL,
            "propagate": False,
        },
        "lumina.http": {
            "handlers":  ["console"],
            "level":     "INFO",
            "propagate": False,
        },
        "django.server": {
            "handlers":  ["console"],
            "level":     "WARNING",
            "propagate": False,
        },
        "django.request": {
            "handlers":  ["console"],
            "level":     "WARNING",
            "propagate": False,
        },
        "pyads": {
            "handlers":  ["console"],
            "level":     "WARNING",
            "propagate": False,
        },
    },
}

# Create logs directory if it doesn't exist
_logs_dir = BASE_DIR / "logs"
_logs_dir.mkdir(exist_ok=True)

# ── Django REST Framework ─────────────────────────────────────────────────────

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
    "DEFAULT_RENDERER_CLASSES": [
        "rest_framework.renderers.JSONRenderer",
    ],
    "DEFAULT_THROTTLE_CLASSES": [],  # handled by our own middleware
    "EXCEPTION_HANDLER": "find_device.auth_views.drf_exception_handler",
}

# ── JWT ───────────────────────────────────────────────────────────────────────

from datetime import timedelta  # noqa: E402

SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME":  timedelta(minutes=30),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=7),
    "ROTATE_REFRESH_TOKENS":  True,
    "BLACKLIST_AFTER_ROTATION": True,
    "UPDATE_LAST_LOGIN": True,
    "ALGORITHM": "HS256",
    "SIGNING_KEY": SECRET_KEY,
    "AUTH_HEADER_TYPES": ("Bearer",),
    "USER_ID_FIELD": "id",
    "USER_ID_CLAIM": "user_id",
    "TOKEN_OBTAIN_SERIALIZER": "find_device.auth_views.LuminaTokenObtainSerializer",
}

# ── Authentication ────────────────────────────────────────────────────────────
# Every /plc/ endpoint controls real building hardware (lighting, security
# arm/disarm, lockdown) and must require a signed-in user so each action can
# be attributed to a person. Set PLC_REQUIRE_AUTH=False only for isolated
# local tooling that intentionally bypasses login (e.g. a curl smoke test).

PLC_REQUIRE_AUTH = os.getenv("PLC_REQUIRE_AUTH", "True").lower() == "true"

# ── Celery ────────────────────────────────────────────────────────────────────
# Workers handle: PLC polling, alarm notifications, audit log archival,
# scheduled energy reports, temporary-access expiry sweeps.

CELERY_BROKER_URL          = os.getenv("REDIS_URL", "redis://localhost:6379/0")
CELERY_RESULT_BACKEND      = os.getenv("REDIS_URL", "redis://localhost:6379/0")
CELERY_ACCEPT_CONTENT      = ["json"]
CELERY_TASK_SERIALIZER     = "json"
CELERY_RESULT_SERIALIZER   = "json"
CELERY_TIMEZONE            = TIME_ZONE
CELERY_ENABLE_UTC          = True

# Task routing — separate queues so heavy PLC polling doesn't block notifications
CELERY_TASK_ROUTES = {
    "find_device.tasks.poll_plc_state":        {"queue": "plc"},
    "find_device.tasks.check_alarms":          {"queue": "alarms"},
    "find_device.tasks.expire_temporary_access":{"queue": "housekeeping"},
    "find_device.tasks.archive_audit_log":     {"queue": "housekeeping"},
    "find_device.tasks.send_notification":     {"queue": "notifications"},
}

# Beat schedule — periodic tasks
from celery.schedules import crontab  # noqa: E402

CELERY_BEAT_SCHEDULE = {
    # Poll every registered PLC device every 1 s — matches AppState's
    # client poll interval (see its comment, 2026-08-19: this is as fast as
    # this WinCE CX8190's ADS layer can safely sustain without repeating
    # the connection instability this session spent hours fixing).
    "poll-plc-state": {
        "task":     "find_device.tasks.poll_plc_state",
        "schedule": 1.0,
        "options":  {"queue": "plc"},
    },
    # Alarm threshold check every 5 s
    "check-alarms": {
        "task":     "find_device.tasks.check_alarms",
        "schedule": 5.0,
        "options":  {"queue": "alarms"},
    },
    # Sweep expired temporary-access grants every minute
    "expire-temporary-access": {
        "task":     "find_device.tasks.expire_temporary_access",
        "schedule": crontab(minute="*"),
        "options":  {"queue": "housekeeping"},
    },
    # PLC reachability heartbeat — alert on real outages/recoveries, every minute
    "check-plc-heartbeat": {
        "task":     "find_device.tasks.check_plc_heartbeat",
        "schedule": crontab(minute="*"),
        "options":  {"queue": "housekeeping"},
    },
    # Archive audit log entries older than 90 days at 02:00 UTC daily
    "archive-audit-log": {
        "task":     "find_device.tasks.archive_audit_log",
        "schedule": crontab(hour=2, minute=0),
        "options":  {"queue": "housekeeping"},
    },
    # pg_dump the database + prune old backups at 03:00 UTC daily — after
    # archive-audit-log so they don't compete for the same table locks
    "backup-database": {
        "task":     "find_device.tasks.backup_database",
        "schedule": crontab(hour=3, minute=0),
        "options":  {"queue": "housekeeping"},
    },
}
