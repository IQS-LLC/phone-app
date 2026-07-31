"""
ADS communication layer.

Single threaded-safe connection to TwinCAT/ADS runtime.  All device
objects share one ADSClient instance via the DeviceRegistry.

Reconnect strategy: on any read/write failure the connection is marked as
lost and an exponential-backoff background thread attempts reconnection
automatically.  Callers may also catch ConnectionError and surface it as a
503 in the API layer.
"""
from __future__ import annotations

import logging
import math
import os
import threading
import time
from collections import deque
from typing import Any, Dict, List, Optional

import pyads

logger = logging.getLogger(__name__)

# ── ADS state name lookup ─────────────────────────────────────────────────────

_ADS_STATE_NAMES: Dict[int, str] = {
    0:  "INVALID",
    1:  "IDLE",
    2:  "RESET",
    3:  "INIT",
    4:  "START",
    5:  "RUN",
    6:  "STOP",
    7:  "SAVECFG",
    8:  "LOADCFG",
    9:  "POWERFAIL",
    10: "POWERGOOD",
    11: "ERROR",
    12: "SHUTDOWN",
    13: "SUSPEND",
    14: "RESUME",
    15: "CONFIG",
    16: "RECONFIG",
}


class ADSClient:
    """
    Thread-safe wrapper around a pyads.Connection.

    Supports real PLC and mock mode.  Mock mode skips all pyads calls;
    device objects supply their own in-memory state for mock responses.

    New in this revision
    --------------------
    * Connection health counters and latency tracking.
    * Exponential-backoff auto-reconnect running in a daemon background thread.
    * Device/state information methods.
    * Batch read/write via pyads symbol lists.
    * Symbol handle cache for high-frequency reads.
    * Full symbol enumeration.
    * Route management helper.
    * ``health`` property aggregating all diagnostics.
    """

    # ── Reconnect parameters ──────────────────────────────────────────────────
    _reconnect_delay     = 1.0    # initial back-off interval (seconds)
    _reconnect_max_delay = 60.0   # cap on back-off interval

    # ── Auto route-repair ─────────────────────────────────────────────────────
    # TwinCAT engineering sessions (project rebuild/reactivate/redownload)
    # can reset the target's AMS route table, silently dropping whatever
    # route lets this host talk to it. Rather than requiring someone to
    # notice and re-run add_route_to_plc by hand, connect() does it
    # automatically on failure — gated by a cooldown so a persistently
    # unreachable target doesn't get hammered with route-add attempts.
    #
    # 15s was too aggressive: re-registering a route can reset the target's
    # route-table entry for that identity, which can knock out *any other*
    # client currently using it (e.g. TwinCAT XAE's own engineering session,
    # if it happens to share this identity). During a stretch where the CX
    # was struggling to stay connected at all, this fired roughly every
    # 60-70s (once the exponential backoff maxed out and looped), which was
    # enough to repeatedly disrupt a live XAE session. 10 minutes is long
    # enough that a genuinely cleared route still gets fixed automatically
    # without being a repeated background disruption.
    _ROUTE_REPAIR_COOLDOWN = 600.0
    _last_route_repair_attempt = 0.0

    def __init__(self, netid: str, ip: str, mock: bool = False):
        self.netid = netid
        self.ip    = ip
        self.mock  = mock

        self._conn:   Optional[pyads.Connection] = None
        self._lock    = threading.RLock()

        # ── State flags ───────────────────────────────────────────────────────
        self._connected       = False
        self._connected_since: Optional[float] = None   # monotonic

        # ── Health counters ───────────────────────────────────────────────────
        self._read_count:  int = 0
        self._write_count: int = 0
        self._error_count: int = 0
        self._reconnect_count: int = 0
        self._latency_samples: deque = deque(maxlen=50)   # ms per read

        self._last_error:      Optional[str]   = None
        self._last_error_time: Optional[float] = None    # monotonic

        # ── ADS state ─────────────────────────────────────────────────────────
        self._ads_state: str = "UNKNOWN"

        # ── Reconnect thread ──────────────────────────────────────────────────
        self._reconnect_lock   = threading.Lock()
        self._reconnect_thread: Optional[threading.Thread] = None
        self._stop_reconnect   = threading.Event()

        # ── Symbol handle cache ───────────────────────────────────────────────
        self._handle_cache: Dict[str, int] = {}

        # Last exception from _open_and_verify(), used by connect() to decide
        # whether a route repair could plausibly help (see
        # _should_attempt_route_repair).
        self._last_connect_exc: Optional[Exception] = None

    # =========================================================================
    # Connection lifecycle
    # =========================================================================

    def connect(self) -> bool:
        """
        Open the ADS connection.  Returns True on success or in mock mode.

        Deliberately does NOT hold self._lock across the network I/O below
        (which can take 5-10s+ per attempt against a slow/unreachable
        target) — read()/write()/read_batch() all acquire that same lock
        just to check "are we connected", and this method runs on the
        background reconnect thread while those run on request threads.
        Holding the lock here would block every other request for the
        full duration of one reconnect attempt — exactly the stall the
        background thread exists to avoid causing. Only the brief instant
        of publishing a verified connection (in _open_and_verify) is
        locked.
        """
        if self.mock:
            self._connected       = True
            self._connected_since = time.monotonic()
            logger.info("ADSClient: mock mode – no real PLC connection")
            return True

        if self._connected:
            return True
        if self._open_and_verify():
            return True

        # open()/read_state() failed. Only worth trying an automatic route
        # repair if the failure actually looks like a missing route (see
        # _should_attempt_route_repair) — otherwise this just burns the
        # repair cooldown on a target that repair can't fix, blocking a
        # real route-loss from being repaired for the next 10 minutes.
        if self._should_attempt_route_repair() and self._try_auto_route_repair():
            if self._open_and_verify():
                logger.info(
                    "ADSClient: connected after automatic route repair  "
                    "netid=%s  ip=%s", self.netid, self.ip,
                )
                return True

        with self._lock:
            self._conn      = None
            self._connected = False
        return False

    def _open_and_verify(self) -> bool:
        """
        Open a pyads.Connection and confirm it's actually usable.

        pyads' open() can succeed at the raw TCP level even when the
        target's AMS router doesn't recognize this sender — the failure
        only shows up on the first real ADS command. read_state() here
        is that real command, so _connected only ever reflects a
        connection that has actually proven it works.

        The slow part (open + read_state) runs without self._lock held —
        see connect(). Only the final publish step is locked.
        """
        try:
            conn = pyads.Connection(self.netid, pyads.PORT_TC3PLC1, self.ip)
            conn.open()
            conn.read_state()
            with self._lock:
                self._conn            = conn
                self._connected        = True
                self._connected_since  = time.monotonic()
            self._last_connect_exc = None
            logger.info(
                "ADSClient: connected  netid=%s  ip=%s", self.netid, self.ip
            )
            return True
        except Exception as exc:
            self._last_connect_exc = exc
            self._record_error(str(exc))
            logger.error("ADSClient: connect failed: %s", exc)
            return False

    # ADS error 7 ("Target machine not found - Missing ADS routes") is the
    # one failure mode a route repair can actually fix — it means the AMS
    # router genuinely has no route entry for us. Error 6 ("Target port not
    # found - ADS Server not started") looks superficially similar but means
    # something route-repair is powerless against: either the target's ADS
    # router itself isn't reachable (device off/rebooting/network down —
    # confirmed by raw TCP + ARP tests to be the common real-world cause
    # here) or the PLC runtime just isn't started yet on a router that's
    # otherwise fine. Repairing the route in either case can't help and
    # only wastes the _ROUTE_REPAIR_COOLDOWN window that should be reserved
    # for a genuine route-table reset.
    _ROUTE_MISSING_CODES = frozenset({7})  # ADSERR_TARGET_MACHINE_NOT_FOUND

    def _should_attempt_route_repair(self) -> bool:
        exc = self._last_connect_exc
        if isinstance(exc, pyads.ADSError):
            return getattr(exc, "err_code", None) in self._ROUTE_MISSING_CODES
        # Unknown/non-ADS exception (e.g. a raw socket error pyads didn't
        # wrap) — keep the old behavior of trying a repair, since we don't
        # have enough information to rule it out.
        return True

    def _try_auto_route_repair(self) -> bool:
        """
        Re-register this host's AMS route on the target via the same
        mechanism TwinCAT's own "Add Route" dialog uses, using credentials
        from PLC_ROUTE_USERNAME/PLC_ROUTE_PASSWORD.

        Gated by _ROUTE_REPAIR_COOLDOWN so a target that's genuinely down
        (not just missing a route) doesn't get hammered with route-add
        attempts on every reconnect cycle.

        Must be called with self._lock held.
        """
        now = time.monotonic()
        if now - self._last_route_repair_attempt < self._ROUTE_REPAIR_COOLDOWN:
            return False
        self._last_route_repair_attempt = now

        username     = os.getenv("PLC_ROUTE_USERNAME")
        password     = os.getenv("PLC_ROUTE_PASSWORD")
        local_netid  = os.getenv("LOCAL_AMS_NET_ID")
        local_host   = os.getenv("LOCAL_AMS_HOST")
        if not (username and password and local_netid and local_host):
            logger.debug(
                "ADSClient: auto route repair skipped — "
                "PLC_ROUTE_USERNAME/PLC_ROUTE_PASSWORD/LOCAL_AMS_NET_ID/"
                "LOCAL_AMS_HOST not fully configured"
            )
            return False

        try:
            pyads.add_route_to_plc(
                local_netid, local_host, self.ip, username, password,
                route_name="Lugh-NAS-auto",
            )
            logger.warning(
                "ADSClient: auto-repaired AMS route on %s for %s "
                "(target likely reset its route table)", self.ip, local_netid,
            )
            return True
        except Exception as exc:
            logger.error("ADSClient: auto route repair failed: %s", exc)
            return False

    def disconnect(self):
        """Close the ADS connection and release all handles."""
        with self._lock:
            self.release_all_handles()
            if self._conn:
                try:
                    self._conn.close()
                except Exception:
                    pass
                self._conn = None
            self._connected       = False
            self._connected_since = None

    def _record_error(self, msg: str):
        """Update error counters and store the last error string (call under lock)."""
        self._error_count    += 1
        self._last_error      = msg
        self._last_error_time = time.monotonic()

    # ── Legacy synchronous reconnect (kept for backward compat) ──────────────

    def _ensure_connected(self) -> bool:
        """
        Returns True only if already connected — never blocks.

        This used to fall through to a synchronous reconnect attempt here
        (full ADS connect + optional route repair, 5-25s when the target is
        slow/unreachable) run inline on whatever thread called read/write.
        With WEB_CONCURRENCY=1, that blocked the sole gunicorn worker for
        every other request — including simple health checks — for the
        entire duration of one device's reconnect attempt. Reconnection is
        already handled asynchronously by the background reconnect thread
        (see _reconnect_loop); this just makes sure that thread is running
        and reports "not connected" immediately instead of also trying to
        connect synchronously on the caller's thread.
        """
        if self._connected:
            return True
        self._launch_reconnect_thread()
        return False

    # ── Background auto-reconnect ─────────────────────────────────────────────

    def _launch_reconnect_thread(self):
        """Start the background reconnect daemon if not already running."""
        with self._reconnect_lock:
            if self._reconnect_thread and self._reconnect_thread.is_alive():
                return   # already running
            self._stop_reconnect.clear()
            t = threading.Thread(
                target=self._reconnect_loop,
                name="ads-reconnect",
                daemon=True,
            )
            self._reconnect_thread = t
            t.start()

    def _reconnect_loop(self):
        """
        Exponential-backoff reconnect loop running in a background daemon thread.

        Delay formula: min(initial * 2^attempt, max_delay)
        Resets attempt counter on successful reconnect.
        """
        attempt = 0
        while not self._stop_reconnect.is_set():
            delay = min(
                self._reconnect_delay * math.pow(2, attempt),
                self._reconnect_max_delay,
            )
            logger.info(
                "ADSClient: reconnect attempt %d in %.1f s …", attempt + 1, delay
            )
            self._stop_reconnect.wait(delay)
            if self._stop_reconnect.is_set():
                break

            # Already reconnected by some other path?
            if self._connected:
                break

            self.disconnect()
            ok = self.connect()
            if ok:
                self._reconnect_count += 1
                logger.info("ADSClient: reconnected after %d attempt(s)", attempt + 1)
                break
            attempt += 1

    def stop_reconnect(self):
        """Signal the background reconnect thread to exit cleanly."""
        self._stop_reconnect.set()

    # ADS error codes that mean "this specific symbol doesn't exist / doesn't
    # match the currently-loaded PLC program" — a compile-time mismatch, not
    # a connectivity problem. A device with no real hardware backing (e.g.
    # curtains — see devices.py) hits this on every single poll forever;
    # treating it as a dropped connection tore the whole ADS session down
    # and rebuilt it every ~2s, continuously, which risked exactly the kind
    # of route/session churn on the CX this project has been fighting.
    _SYMBOL_ERROR_CODES = frozenset({
        1808,  # ADSERR_DEVICE_SYMBOLNOTFOUND
        1809,  # ADSERR_DEVICE_SYMBOLVERSIONINVALID (stale handle after a
               # PLC rebuild/download changed the symbol table)
    })

    @classmethod
    def _is_symbol_error(cls, exc: Exception) -> bool:
        return isinstance(exc, pyads.ADSError) and getattr(exc, 'err_code', None) in cls._SYMBOL_ERROR_CODES

    def _mark_disconnected_and_reconnect(self, reason: str):
        """Mark connection as lost and trigger background reconnect."""
        with self._lock:
            self._connected = False
            self._record_error(reason)
        self._launch_reconnect_thread()

    # =========================================================================
    # Core variable I/O  (backward-compatible API)
    # =========================================================================

    def read(self, var_name: str, plctype: Any) -> Any:
        """
        Read a named PLC variable.

        Raises:
            RuntimeError: if called in mock mode (devices handle mock reads).
            ConnectionError: if the PLC is unreachable.
        """
        if self.mock:
            raise RuntimeError(
                "ADSClient.read() called in mock mode – "
                "device objects must handle mock reads internally"
            )
        with self._lock:
            if not self._ensure_connected():
                raise ConnectionError(
                    f"ADS not connected (target {self.netid} @ {self.ip})"
                )
            t_start = time.monotonic()
            try:
                value = self._conn.read_by_name(var_name, plctype)
                elapsed_ms = (time.monotonic() - t_start) * 1000.0
                self._latency_samples.append(elapsed_ms)
                self._read_count += 1
                return value
            except Exception as exc:
                err = str(exc)
                logger.error("ADSClient: read '%s' failed: %s", var_name, err)
                if not self._is_symbol_error(exc):
                    self._mark_disconnected_and_reconnect(err)
                raise ConnectionError(err) from exc

    def write(self, var_name: str, value: Any, plctype: Any):
        """
        Write a named PLC variable.

        In mock mode this is a no-op (device objects manage mock state).

        Raises:
            ConnectionError: if the PLC is unreachable.
        """
        if self.mock:
            return   # device's mock state is managed internally
        with self._lock:
            if not self._ensure_connected():
                raise ConnectionError(
                    f"ADS not connected (target {self.netid} @ {self.ip})"
                )
            try:
                self._conn.write_by_name(var_name, value, plctype)
                self._write_count += 1
            except Exception as exc:
                err = str(exc)
                logger.error("ADSClient: write '%s' failed: %s", var_name, err)
                if not self._is_symbol_error(exc):
                    self._mark_disconnected_and_reconnect(err)
                raise ConnectionError(err) from exc

    # =========================================================================
    # Batch reads / writes
    # =========================================================================

    def read_batch(self, var_type_map: Dict[str, Any]) -> Dict[str, Any]:
        """
        Read multiple PLC variables in a single ADS call.

        Args:
            var_type_map: ``{"GVL.variable": pyads.PLCTYPE_INT, ...}``

        Returns:
            Dict of variable name → value, or ``{}`` on failure.
        """
        if self.mock:
            return {}

        with self._lock:
            if not self._ensure_connected():
                logger.warning("ADSClient.read_batch: not connected")
                return {}
            t_start = time.monotonic()
            try:
                result = self._conn.read_list_by_name(var_type_map)
                elapsed_ms = (time.monotonic() - t_start) * 1000.0
                self._latency_samples.append(elapsed_ms)
                self._read_count += len(var_type_map)
                return result if result else {}
            except Exception as exc:
                err = str(exc)
                logger.error("ADSClient.read_batch failed: %s", err)
                if not self._is_symbol_error(exc):
                    self._mark_disconnected_and_reconnect(err)
                return {}

    def write_batch(self, var_value_map: Dict[str, Any]):
        """
        Write multiple PLC variables in a single ADS call.

        Args:
            var_value_map: ``{"GVL.variable": value, ...}``

        Note:
            pyads resolves each variable's ADS type from the symbol table
            automatically — write_list_by_name takes no explicit type map.
        """
        if self.mock:
            return

        with self._lock:
            if not self._ensure_connected():
                logger.warning("ADSClient.write_batch: not connected")
                return
            try:
                self._conn.write_list_by_name(var_value_map)
                self._write_count += len(var_value_map)
            except Exception as exc:
                err = str(exc)
                logger.error("ADSClient.write_batch failed: %s", err)
                if not self._is_symbol_error(exc):
                    self._mark_disconnected_and_reconnect(err)

    # =========================================================================
    # Symbol handle cache
    # =========================================================================

    def get_handle(self, var_name: str) -> Optional[int]:
        """
        Return (and cache) the ADS handle for a named variable.

        Args:
            var_name: Fully qualified PLC variable name.

        Returns:
            Integer handle, or None if unavailable (mock / error).
        """
        if self.mock:
            return None

        with self._lock:
            if var_name in self._handle_cache:
                return self._handle_cache[var_name]

            if not self._ensure_connected():
                return None

            try:
                handle = self._conn.get_handle(var_name)
                self._handle_cache[var_name] = handle
                return handle
            except Exception as exc:
                logger.warning(
                    "ADSClient.get_handle('%s') failed: %s", var_name, exc
                )
                return None

    def release_all_handles(self):
        """
        Release every cached ADS handle back to the PLC.

        Called automatically on disconnect.  Safe to call even when not
        connected (clears the local cache regardless).
        """
        if self.mock or not self._handle_cache:
            self._handle_cache.clear()
            return

        conn = self._conn
        for var_name, handle in list(self._handle_cache.items()):
            if conn:
                try:
                    conn.release_handle(handle)
                except Exception as exc:
                    logger.debug(
                        "ADSClient: release handle '%s' error: %s", var_name, exc
                    )
        self._handle_cache.clear()

    def read_by_handle(self, handle: int, plctype: Any) -> Any:
        """
        Read a PLC variable via a pre-fetched ADS handle.

        Faster than read_by_name for high-frequency reads because it
        skips the name-resolution step on the PLC.

        Args:
            handle:  ADS handle obtained from get_handle().
            plctype: pyads PLCTYPE_* constant.

        Returns:
            Read value.

        Raises:
            ConnectionError: if the PLC is unreachable.
        """
        if self.mock:
            raise RuntimeError(
                "ADSClient.read_by_handle() called in mock mode"
            )

        with self._lock:
            if not self._ensure_connected():
                raise ConnectionError(
                    f"ADS not connected (target {self.netid} @ {self.ip})"
                )
            t_start = time.monotonic()
            try:
                value = self._conn.read(
                    pyads.constants.ADSIGRP_SYM_VALBYHND, handle, plctype
                )
                elapsed_ms = (time.monotonic() - t_start) * 1000.0
                self._latency_samples.append(elapsed_ms)
                self._read_count += 1
                return value
            except Exception as exc:
                err = str(exc)
                logger.error("ADSClient.read_by_handle(%d) failed: %s", handle, err)
                if not self._is_symbol_error(exc):
                    self._mark_disconnected_and_reconnect(err)
                raise ConnectionError(err) from exc

    def write_by_handle(self, handle: int, value: Any, plctype: Any):
        """
        Write a PLC variable via a pre-fetched ADS handle.

        Args:
            handle:  ADS handle obtained from get_handle().
            value:   Value to write.
            plctype: pyads PLCTYPE_* constant.

        Raises:
            ConnectionError: if the PLC is unreachable.
        """
        if self.mock:
            return

        with self._lock:
            if not self._ensure_connected():
                raise ConnectionError(
                    f"ADS not connected (target {self.netid} @ {self.ip})"
                )
            try:
                self._conn.write(
                    pyads.constants.ADSIGRP_SYM_VALBYHND, handle, value, plctype
                )
                self._write_count += 1
            except Exception as exc:
                err = str(exc)
                logger.error("ADSClient.write_by_handle(%d) failed: %s", handle, err)
                if not self._is_symbol_error(exc):
                    self._mark_disconnected_and_reconnect(err)
                raise ConnectionError(err) from exc

    # =========================================================================
    # Device / state information
    # =========================================================================

    def get_device_info(self) -> dict:
        """
        Retrieve TwinCAT device name and version from the ADS target.

        Returns:
            ``{"name": str, "version": str, "major": int, "minor": int}``

            In mock mode returns a synthetic Lugh Mock PLC descriptor.
        """
        if self.mock:
            return {
                "name":    "Lugh Mock PLC",
                "version": "3.1.4.68",
                "major":   3,
                "minor":   1,
            }

        with self._lock:
            if not self._ensure_connected():
                return {"name": "unavailable", "version": "", "major": 0, "minor": 0}
            try:
                # read_device_info() returns (name: str, AdsVersion), not an
                # object with .name/.version — AdsVersion's fields are
                # .version (major), .revision (minor), .build.
                name, version_obj = self._conn.read_device_info()
                major = version_obj.version
                minor = version_obj.revision
                build = version_obj.build
                return {
                    "name":    name or "",
                    "version": f"{major}.{minor}.{build}",
                    "major":   major,
                    "minor":   minor,
                }
            except Exception as exc:
                logger.warning("ADSClient.get_device_info failed: %s", exc)
                return {"name": "error", "version": "", "major": 0, "minor": 0}

    def read_ads_state(self) -> dict:
        """
        Read the current ADS state and device state from the target.

        Returns:
            ``{"ads_state": int, "ads_state_name": str, "device_state": int}``

            In mock mode returns RUN state.
        """
        if self.mock:
            self._ads_state = "RUN"
            return {"ads_state": 5, "ads_state_name": "RUN", "device_state": 0}

        with self._lock:
            if not self._ensure_connected():
                return {"ads_state": -1, "ads_state_name": "UNKNOWN", "device_state": -1}
            try:
                ads_state, device_state = self._conn.read_state()
                state_name = _ADS_STATE_NAMES.get(int(ads_state), "UNKNOWN")
                self._ads_state = state_name
                return {
                    "ads_state":      int(ads_state),
                    "ads_state_name": state_name,
                    "device_state":   int(device_state),
                }
            except Exception as exc:
                logger.warning("ADSClient.read_ads_state failed: %s", exc)
                return {"ads_state": -1, "ads_state_name": "UNKNOWN", "device_state": -1}

    # =========================================================================
    # Symbol enumeration
    # =========================================================================

    # Prefixes to filter out internal TwinCAT bookkeeping symbols
    _INTERNAL_PREFIXES = ("TwinCAT_SystemInfoVarList", "Constants", "TwinCAT_System")

    def get_all_symbols(self) -> List[dict]:
        """
        Enumerate all symbols declared in the TwinCAT runtime.

        Internal TwinCAT symbols (no dot in name, or matching known internal
        prefixes) are filtered out.

        Returns:
            List of dicts with keys:
            ``full_name``, ``type_name``, ``comment``,
            ``index_group``, ``index_offset``, ``byte_size``.

            Returns ``[]`` in mock mode or on error.
        """
        if self.mock:
            return []

        with self._lock:
            if not self._ensure_connected():
                return []
            try:
                raw_symbols = self._conn.get_all_symbols()
            except Exception as exc:
                logger.warning("ADSClient.get_all_symbols failed: %s", exc)
                return []

        result: List[dict] = []
        for sym in raw_symbols:
            name = getattr(sym, "name", "") or getattr(sym, "symbol_name", "")
            if not name:
                continue
            # Skip symbols with no dot (pure top-level runtime vars, not GVL members)
            if "." not in name:
                continue
            # Skip internal TwinCAT namespaces
            if any(name.startswith(pfx) for pfx in self._INTERNAL_PREFIXES):
                continue
            result.append({
                "full_name":    name,
                "type_name":    getattr(sym, "type_name",    "") or getattr(sym, "dataTypeName", ""),
                "comment":      getattr(sym, "comment",      ""),
                "index_group":  getattr(sym, "index_group",  0),
                "index_offset": getattr(sym, "index_offset", 0),
                "byte_size":    getattr(sym, "byte_size",    0),
            })
        return result

    # =========================================================================
    # Route management
    # =========================================================================

    def add_route(
        self,
        sender_net_id: str,
        sender_host: str,
        username: str,
        password: str,
        route_name: str = "Lugh",
    ) -> bool:
        """
        Add an ADS route on the remote target that points back to this host.

        Args:
            sender_net_id: AMS Net ID of the sender (this host).
            sender_host:   Hostname or IP of the sender (this host).
            username:      Username on the target PLC/embedded OS.
            password:      Password on the target PLC/embedded OS.
            route_name:    Friendly name for the route entry on the PLC.

        Returns:
            True on success, False on error.
        """
        if self.mock:
            logger.debug("ADSClient.add_route: mock mode – skipped")
            return True

        try:
            pyads.add_route_to_plc(
                sender_net_id,
                sender_host,
                self.ip,
                username,
                password,
                route_name=route_name,
            )
            logger.info(
                "ADSClient.add_route: added route '%s' on %s", route_name, self.netid
            )
            return True
        except Exception as exc:
            logger.error("ADSClient.add_route failed: %s", exc)
            return False

    # =========================================================================
    # Health / diagnostic properties
    # =========================================================================

    @property
    def avg_latency_ms(self) -> float:
        """Mean read latency over the last 50 samples, in milliseconds."""
        samples = list(self._latency_samples)
        if not samples:
            return 0.0
        return sum(samples) / len(samples)

    @property
    def error_rate(self) -> float:
        """Fraction of operations that resulted in errors (0.0 – 1.0)."""
        total = self._read_count + self._write_count
        if total == 0:
            return 0.0
        return self._error_count / total

    @property
    def health(self) -> dict:
        """
        Aggregated diagnostic snapshot.

        Keys
        ----
        connected       bool   – whether the ADS connection is currently open
        mock            bool   – True when running in mock mode
        netid           str    – AMS Net ID of the target
        ip              str    – IP address of the target
        ads_state       str    – last known ADS state string ("RUN", "STOP", …)
        uptime_s        float  – seconds since last successful connect (0 if down)
        read_count      int    – total successful reads since instantiation
        write_count     int    – total successful writes since instantiation
        error_count     int    – total ADS errors since instantiation
        error_rate      float  – error_count / (read_count + write_count)
        avg_latency_ms  float  – mean read latency over last 50 samples
        last_error      str|None  – message from the most recent ADS error
        last_error_time float|None – monotonic timestamp of the last error
        reconnect_count int    – number of successful auto-reconnects
        """
        uptime = 0.0
        if self._connected_since is not None and self._connected:
            uptime = time.monotonic() - self._connected_since

        return {
            "connected":       self._connected,
            "mock":            self.mock,
            "netid":           self.netid,
            "ip":              self.ip,
            "ads_state":       self._ads_state,
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

    # =========================================================================
    # Legacy property
    # =========================================================================

    @property
    def is_connected(self) -> bool:
        """True if the ADS connection is currently open."""
        return self._connected
