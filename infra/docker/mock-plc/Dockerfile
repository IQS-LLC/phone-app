FROM python:3.11-slim

WORKDIR /app

# System dependencies for pysoem/scapy
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpcap-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

# ADS port
EXPOSE 48898
# HTTP management API
EXPOSE 8080

ENV ADS_PORT=48898
ENV HTTP_PORT=8080
ENV DALI_CHANNELS=16
ENV RELAY_CHANNELS=4

# Non-root user
RUN useradd -r -s /bin/false plc
USER plc

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

CMD ["python", "server.py"]
