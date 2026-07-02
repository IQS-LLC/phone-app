import os

bind = "0.0.0.0:8000"
backlog = 2048

# DeviceRegistry (find_device/plc/registry.py) holds one in-memory ADS
# connection per apartment, keyed in a process-local dict. Each gunicorn
# worker is a separate process, so >1 worker means >1 independent ADS
# connection per PLC and state that can disagree between workers. Until PLC
# state is moved to a shared backend (Redis/Celery), this must stay at 1.
# Override only if you understand that tradeoff.
workers = int(os.getenv("GUNICORN_WORKERS", "1"))
worker_class = "sync"
worker_connections = 1000
timeout = 30
keepalive = 2

max_requests = 1000
max_requests_jitter = 50

loglevel = os.getenv("GUNICORN_LOG_LEVEL", "info")
accesslog = "-"
errorlog = "-"

proc_name = "plc_django"

daemon = False
pidfile = "/tmp/gunicorn.pid"

# Removed hardcoded user/group — let Docker handle this
tmp_upload_dir = None

keyfile = None
certfile = None