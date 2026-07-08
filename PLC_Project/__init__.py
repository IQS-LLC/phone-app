try:
    from .celery import app as celery_app
    __all__ = ("celery_app",)
except ImportError:
    pass  # Celery not installed — Django still runs for migrate/dev without it
