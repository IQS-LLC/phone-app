"""
ADS communication layer.

Single threaded-safe connection to TwinCAT/ADS runtime. All device
objects share one ADSClient instance via the DeviceRegistry.

Reconnect strategy: on any read/write failure the connection is
marked as lost and the next operation triggers a reconnect attempt.
Callers catch ConnectionError and surface it as a 503 in the API layer.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Any, Optional

import pyads

logger = logging.getLogger(__name__)


class ADSClient:
    """
    Thread-safe wrapper around a pyads.Connection.

    Supports real PLC and mock mode.  Mock mode skips all pyads calls;
    device objects supply their own in-memory state for mock responses.
    """

    _RECONNECT_COOLDOWN = 5.0   # seconds between reconnect attempts

    def __init__(self, netid: str, ip: str, mock: bool = False):
        self.netid = netid
        self.ip    = ip
        self.mock  = mock

        self._conn:            Optional[pyads.Connection] = None
        self._lock             = threading.RLock()
        self._connected        = False
        self._last_reconnect   = 0.0

    # ── Connection lifecycle ──────────────────────────────────────────────────

    def connect(self) -> bool:
        if self.mock:
            self._connected = True
            logger.info("ADSClient: mock mode – no real PLC connection")
            return True

        with self._lock:
            if self._connected:
                return True
            try:
                self._conn = pyads.Connection(
                    self.netid, pyads.PORT_TC3PLC1, self.ip
                )
                self._conn.open()
                self._connected = True
                logger.info(
                    "ADSClient: connected  netid=%s  ip=%s", self.netid, self.ip
                )
                return True
            except Exception as exc:
                self._conn      = None
                self._connected = False
                logger.error("ADSClient: connect failed: %s", exc)
                return False

    def disconnect(self):
        with self._lock:
            if self._conn:
                try:
                    self._conn.close()
                except Exception:
                    pass
                self._conn = None
            self._connected = False

    def _attempt_reconnect(self) -> bool:
        now = time.monotonic()
        if now - self._last_reconnect < self._RECONNECT_COOLDOWN:
            return False
        self._last_reconnect = now
        logger.warning("ADSClient: attempting reconnect …")
        self.disconnect()
        return self.connect()

    def _ensure_connected(self) -> bool:
        if self._connected:
            return True
        return self._attempt_reconnect()

    # ── Variable I/O ──────────────────────────────────────────────────────────

    def read(self, var_name: str, plctype: Any) -> Any:
        """Read a named PLC variable.  Raises ConnectionError if unreachable."""
        if self.mock:
            raise RuntimeError("ADSClient.read() called in mock mode – "
                               "device objects must handle mock reads internally")
        with self._lock:
            if not self._ensure_connected():
                raise ConnectionError(
                    f"ADS not connected (target {self.netid} @ {self.ip})"
                )
            try:
                return self._conn.read_by_name(var_name, plctype)
            except Exception as exc:
                logger.error("ADSClient: read '%s' failed: %s", var_name, exc)
                self._connected = False
                raise ConnectionError(str(exc)) from exc

    def write(self, var_name: str, value: Any, plctype: Any):
        """Write a named PLC variable.  Raises ConnectionError if unreachable."""
        if self.mock:
            return   # device's mock state is managed internally
        with self._lock:
            if not self._ensure_connected():
                raise ConnectionError(
                    f"ADS not connected (target {self.netid} @ {self.ip})"
                )
            try:
                self._conn.write_by_name(var_name, value, plctype)
            except Exception as exc:
                logger.error("ADSClient: write '%s' failed: %s", var_name, exc)
                self._connected = False
                raise ConnectionError(str(exc)) from exc

    # ── Properties ────────────────────────────────────────────────────────────

    @property
    def is_connected(self) -> bool:
        return self._connected
