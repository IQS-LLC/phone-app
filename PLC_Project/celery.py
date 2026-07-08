import os

from celery import Celery

# Set broker directly from env so it works regardless of Django settings load order.
# config_from_object may override these later with the same value.
_REDIS = os.getenv("REDIS_URL", "redis://localhost:6379/0")

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "PLC_Project.settings")

app = Celery("lugh", broker=_REDIS, backend=_REDIS)
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks()
