"""
Modbus TCP communication layer — companion to ads_client.py.

Talks to the same CX8190, but through TF6250 (TwinCAT Modbus TCP Server)
instead of ADS/AMS. Deliberately mirrors ADSClient's shape (lock,
background reconnect thread, health dict) so DeviceRegistry can treat
either as a drop-in data source for the points POU_Modbus bridges:

    DALI levels 1-16  -> holding/input registers 0-15
    Relays 0-3        -> coils / discrete inputs 0-3
    Curtains 1/2      -> coils / discrete inputs 4-7 (open1, close1, open2, close2)

See Apartmant16/TwinCAT DALI Sensor Project/DALI_PLC/GVLs/GVL.TcGVL for
the authoritative register map and POU_Modbus.TcPOU for the bridging
logic on the PLC side. Modbus has no route table and no symbol
versioning — it exists specifically to keep working through the class of
AMS/Secure-ADS/route-reset failures ads_client.py has had to fight, not
to replace ADS (no symbol names, no discovery, only the 16 DALI + 4
relay + 2 curtain points POU_Modbus explicitly bridges are reachable
this way).
"""
from __future__ import annotations

import logging
import math
import threading
import time
from collections import deque
from typing import Dict, Optional

from pymodbus.client import ModbusTcpClient
from pymodbus.exceptions import ModbusException

logger = logging.getLogger(__name__)

_DEFAULT_PORT    = 502
_DEFAULT_TIMEOUT = 3.0

# Register map — see GVL.TcGVL. Kept here as the single source of truth
# on the Django side so device code never hardcodes raw indices.
DALI_CHANNELS  = 16   # holding/input registers 0-15
RELAY_COUNT    = 4    # coils / discrete inputs 0-3
CURTAIN_COILS  = 4    # coils / discrete inputs 4-7 (open1, close1, open2, close2)


class ModbusClient:
    """
    Thread-safe wrapper around a pymodbus ModbusTcpClient.

    Mirrors ADSClient: mock mode, health counters, exponential-backoff
    auto-reconnect on a background daemon thread, and a small point-level
    API instead of raw register calls, so callers don't need to know the
    register map.
    """

    _reconnect_delay     = 1.0
    _reconnect_max_delay = 60.0

    def __init__(self, ip: str, port: int = _DEFAULT_PORT, unit_id: int = 1, mock: bool = False):
        self.ip      = ip
        self.port    = port
        self.unit_id = unit_id
        self.mock    = mock

        self._client: Optional[ModbusTcpClient] = None
        self._lock    = threading.RLock()

        self._connected       = False
        self._connected_since: Optional[float] = None

        self._read_count:  int = 0
        self._write_count: int = 0
        self._error_count: int = 0
        self._reconnect_count: int = 0
        self._latency_samples: deque = deque(maxlen=50)

        self._last_error:      Optional[str]   = None
        self._last_error_time: Optional[float] = None

        self._reconnect_lock   = threading.Lock()
        self._reconnect_thread: Optional[threading.Thread] = None
        self._stop_reconnect   = threading.Event()

    # =========================================================================
    # Connection lifecycle
    # =========================================================================

    def connect(self) -> bool:
        """Open the Modbus TCP connection. Returns True on success or in mock mode."""
        if self.mock:
            self._connected       = True
            self._connected_since = time.monotonic()
            logger.info("ModbusClient: mock mode – no real PLC connection")
            return True

        if self._connected:
            return True

        try:
            client = ModbusTcpClient(self.ip, port=self.port, timeout=_DEFAULT_TIMEOUT)
            if not client.connect():
                raise ConnectionError(f"could not open Modbus TCP socket to {self.ip}:{self.port}")
            with self._lock:
                self._client           = client
                self._connected        = True
                self._connected_since  = time.monotonic()
            logger.info("ModbusClient: connected  ip=%s  port=%d", self.ip, self.port)
            return True
        except Exception as exc:
            self._record_error(str(exc))
            logger.error("ModbusClient: connect failed: %s", exc)
            return False

    def disconnect(self):
        with self._lock:
            if self._client:
                try:
                    self._client.close()
                except Exception:
                    pass
                self._client = None
            self._connected       = False
            self._connected_since = None

    def _record_error(self, msg: str):
        self._error_count    += 1
        self._last_error      = msg
        self._last_error_time = time.monotonic()

    def _ensure_connected(self) -> bool:
        """Returns True only if already connected — never blocks (see ADSClient)."""
        if self._connected:
            return True
        self._launch_reconnect_thread()
        return False

    def _launch_reconnect_thread(self):
        with self._reconnect_lock:
            if self._reconnect_thread and self._reconnect_thread.is_alive():
                return
            self._stop_reconnect.clear()
            t = threading.Thread(target=self._reconnect_loop, name="modbus-reconnect", daemon=True)
            self._reconnect_thread = t
            t.start()

    def _reconnect_loop(self):
        attempt = 0
        while not self._stop_reconnect.is_set():
            delay = min(self._reconnect_delay * math.pow(2, attempt), self._reconnect_max_delay)
            logger.info("ModbusClient: reconnect attempt %d in %.1f s …", attempt + 1, delay)
            self._stop_reconnect.wait(delay)
            if self._stop_reconnect.is_set():
                break
            if self._connected:
                break
            self.disconnect()
            if self.connect():
                self._reconnect_count += 1
                logger.info("ModbusClient: reconnected after %d attempt(s)", attempt + 1)
                break
            attempt += 1

    def stop_reconnect(self):
        self._stop_reconnect.set()

    def _mark_disconnected_and_reconnect(self, reason: str):
        with self._lock:
            self._connected = False
            self._record_error(reason)
        self._launch_reconnect_thread()

    # =========================================================================
    # Point-level API — the only points POU_Modbus bridges (see module docstring)
    # =========================================================================

    def read_dali_level(self, channel: int) -> Optional[int]:
        """Read a DALI channel's actual level (1-16). Returns 0-254, or None on failure."""
        if self.mock:
            return None
        if channel < 1 or channel > DALI_CHANNELS:
            raise ValueError(f"channel must be 1-{DALI_CHANNELS}")
        return self._read_one("read_input_registers", channel - 1)

    def write_dali_level(self, channel: int, value: int) -> bool:
        """Write a DALI channel's set-level (1-16), 0-254."""
        if self.mock:
            return True
        if channel < 1 or channel > DALI_CHANNELS:
            raise ValueError(f"channel must be 1-{DALI_CHANNELS}")
        return self._write_one("write_register", channel - 1, value)

    def read_relay(self, relay: int) -> Optional[bool]:
        """Read relay actual state (0-3)."""
        if self.mock:
            return None
        if relay < 0 or relay >= RELAY_COUNT:
            raise ValueError(f"relay must be 0-{RELAY_COUNT - 1}")
        return self._read_one("read_discrete_inputs", relay)

    def write_relay(self, relay: int, value: bool) -> bool:
        """Write relay commanded state (0-3)."""
        if self.mock:
            return True
        if relay < 0 or relay >= RELAY_COUNT:
            raise ValueError(f"relay must be 0-{RELAY_COUNT - 1}")
        return self._write_one("write_coil", relay, value)

    def read_curtain(self, index: int) -> Optional[bool]:
        """Read curtain output state. index: 0=curtain1 open, 1=curtain1 close, 2=curtain2 open, 3=curtain2 close."""
        if self.mock:
            return None
        if index < 0 or index >= CURTAIN_COILS:
            raise ValueError(f"index must be 0-{CURTAIN_COILS - 1}")
        return self._read_one("read_discrete_inputs", RELAY_COUNT + index)

    def write_curtain_button(self, index: int, value: bool) -> bool:
        """Write curtain button state (held-while-true). Same index convention as read_curtain."""
        if self.mock:
            return True
        if index < 0 or index >= CURTAIN_COILS:
            raise ValueError(f"index must be 0-{CURTAIN_COILS - 1}")
        return self._write_one("write_coil", RELAY_COUNT + index, value)

    # =========================================================================
    # Low-level read/write helpers
    # =========================================================================

    def _read_one(self, fn_name: str, address: int):
        with self._lock:
            if not self._ensure_connected():
                return None
            t_start = time.monotonic()
            try:
                fn = getattr(self._client, fn_name)
                result = fn(address, count=1, device_id=self.unit_id)
                if result.isError():
                    raise ModbusException(f"{fn_name}({address}) returned an error response")
                elapsed_ms = (time.monotonic() - t_start) * 1000.0
                self._latency_samples.append(elapsed_ms)
                self._read_count += 1
                if fn_name in ("read_holding_registers", "read_input_registers"):
                    return result.registers[0]
                return result.bits[0]
            except Exception as exc:
                err = str(exc)
                logger.error("ModbusClient: %s(%d) failed: %s", fn_name, address, err)
                self._mark_disconnected_and_reconnect(err)
                return None

    def _write_one(self, fn_name: str, address: int, value) -> bool:
        with self._lock:
            if not self._ensure_connected():
                return False
            try:
                fn = getattr(self._client, fn_name)
                result = fn(address, value, device_id=self.unit_id)
                if result.isError():
                    raise ModbusException(f"{fn_name}({address}, {value}) returned an error response")
                self._write_count += 1
                return True
            except Exception as exc:
                err = str(exc)
                logger.error("ModbusClient: %s(%d, %s) failed: %s", fn_name, address, value, err)
                self._mark_disconnected_and_reconnect(err)
                return False

    # =========================================================================
    # Health / diagnostics — same shape as ADSClient.health
    # =========================================================================

    @property
    def avg_latency_ms(self) -> float:
        samples = list(self._latency_samples)
        if not samples:
            return 0.0
        return sum(samples) / len(samples)

    @property
    def error_rate(self) -> float:
        total = self._read_count + self._write_count
        if total == 0:
            return 0.0
        return self._error_count / total

    @property
    def health(self) -> dict:
        uptime = 0.0
        if self._connected_since is not None and self._connected:
            uptime = time.monotonic() - self._connected_since
        return {
            "connected":       self._connected,
            "mock":            self.mock,
            "ip":              self.ip,
            "port":            self.port,
            "uptime_s":        uptime,
            "read_count":      self._read_count,
            "write_count":     self._write_count,
            "error_count":     self._error_count,
            "error_rate":      self.error_rate,
            "avg_latency_ms":  self.avg_latency_ms,
            "last_error":      self._last_error,
            "last_error_time": self._last_error_time,
            "reconnect_count": self._reconnect_count,
        }

    @property
    def is_connected(self) -> bool:
        return self._connected
