# Gunicorn configuration for production
import multiprocessing
import os

# Server socket
bind = "0.0.0.0:8000"
backlog = 2048

# Worker processes
workers = multiprocessing.cpu_count() * 2 + 1
worker_class = "sync"
worker_connections = 1000
timeout = 30
keepalive = 2

# Restart workers after this many requests, this can help with memory leaks
max_requests = 1000
max_requests_jitter = 50

# Logging
loglevel = os.getenv("GUNICORN_LOG_LEVEL", "info")
accesslog = "-"
errorlog = "-"

# Process naming
proc_name = "plc_django"

# Server mechanics
daemon = False
pidfile = "/tmp/gunicorn.pid"
user = "app"
group = "app"
tmp_upload_dir = None

# SSL (if needed)
keyfile = None
certfile = None

# Application
wsgi_module = "PLC_Project.wsgi"
callable = "application"