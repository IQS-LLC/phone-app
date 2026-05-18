"""
DeviceRegistry — singleton that owns the ADSClient and all device objects.

Default layout reflects the current TwinCAT project:
  - 16 DALI dimmers  (channels 1-16)
  - 4  wall relays   (channels 1-4)
  - First 4 switch inputs registered (extend as hardware grows)

Rooms / names can be reconfigured here without touching any other file.
New devices are added by calling registry.add_dali(), add_relay(), or
add_switch() at startup (e.g. from Django AppConfig.ready()).
"""
from __future__ import annotations

import logging
import os
import threading
from typing import Dict, List, Optional

from .ads_client import ADSClient
from .devices import DaliChannel, WallRelay, SwitchInput

logger = logging.getLogger(__name__)


# ── Default device layout ─────────────────────────────────────────────────────
# Edit room names and light names here as the installation grows.
# The channel / index numbers MUST match the PLC GVL array indices.

_DEFAULT_DALI: list[dict] = [
    # channel, name,              room
    dict(channel=1,  name='Light 1',  room='Living Room'),
    dict(channel=2,  name='Light 2',  room='Living Room'),
    dict(channel=3,  name='Light 3',  room='Living Room'),
    dict(channel=4,  name='Light 4',  room='Living Room'),
    dict(channel=5,  name='Light 5',  room='Dining Room'),
    dict(channel=6,  name='Light 6',  room='Dining Room'),
    dict(channel=7,  name='Light 7',  room='Dining Room'),
    dict(channel=8,  name='Light 8',  room='Dining Room'),
    dict(channel=9,  name='Light 9',  room='Bedroom 1'),
    dict(channel=10, name='Light 10', room='Bedroom 1'),
    dict(channel=11, name='Light 11', room='Bedroom 2'),
    dict(channel=12, name='Light 12', room='Bedroom 2'),
    dict(channel=13, name='Light 13', room='Kitchen'),
    dict(channel=14, name='Light 14', room='Kitchen'),
    dict(channel=15, name='Light 15', room='Hallway'),
    dict(channel=16, name='Light 16', room='Hallway'),
]

_DEFAULT_RELAYS: list[dict] = [
    dict(channel=1, name='Wall Light 1', room='Living Room'),
    dict(channel=2, name='Wall Light 2', room='Living Room'),
    dict(channel=3, name='Wall Light 3', room='Hallway'),
    dict(channel=4, name='Wall Light 4', room='Hallway'),
]

_DEFAULT_SWITCHES: list[dict] = [
    # index, name,          room
    dict(index=1, name='Switch 1', room='Living Room'),
    dict(index=2, name='Switch 2', room='Living Room'),
    dict(index=3, name='Switch 3', room='Hallway'),
    dict(index=4, name='Switch 4', room='Hallway'),
]


# ── Registry ──────────────────────────────────────────────────────────────────

class DeviceRegistry:
    """
    Central registry for all PLC devices.

    Thread-safe singleton.  All device objects share one ADSClient.
    """

    _instance:       Optional['DeviceRegistry'] = None
    _instance_lock   = threading.Lock()

    def __init__(self):
        mock = os.getenv('PLC_MOCK', 'True').lower() == 'true'
        self._client = ADSClient(
            netid=os.getenv('PLC_NETID', '5.168.214.75.1.1'),
            ip   =os.getenv('PLC_IP',    '192.168.0.161'),
            mock =mock,
        )
        self._dali:     Dict[int, DaliChannel]  = {}
        self._relays:   Dict[int, WallRelay]    = {}
        self._switches: Dict[int, SwitchInput]  = {}
        self._lock      = threading.RLock()
        self._started   = False

    # ── Startup ───────────────────────────────────────────────────────────────

    def _start(self):
        if self._started:
            return
        ok = self._client.connect()
        if not ok and not self._client.mock:
            logger.warning("Real PLC unavailable — running in mock mode")
            self._client.mock = True
            self._client.connect()
        for d in _DEFAULT_DALI:
            self.add_dali(**d)
        for r in _DEFAULT_RELAYS:
            self.add_relay(**r)
        for s in _DEFAULT_SWITCHES:
            self.add_switch(**s)
        self._started = True
        logger.info(
            "DeviceRegistry ready: %d DALI channels, %d relays, %d switches  mock=%s",
            len(self._dali), len(self._relays), len(self._switches),
            self._client.mock,
        )

    # ── Registration helpers ──────────────────────────────────────────────────

    def add_dali(self, channel: int, name: str, room: str):
        with self._lock:
            self._dali[channel] = DaliChannel(channel, name, room, self._client)

    def add_relay(self, channel: int, name: str, room: str):
        with self._lock:
            self._relays[channel] = WallRelay(channel, name, room, self._client)

    def add_switch(self, index: int, name: str, room: str):
        with self._lock:
            self._switches[index] = SwitchInput(index, name, room, self._client)

    # ── Accessors ─────────────────────────────────────────────────────────────

    def dali(self, channel: int) -> Optional[DaliChannel]:
        return self._dali.get(channel)

    def relay(self, channel: int) -> Optional[WallRelay]:
        return self._relays.get(channel)

    def switch(self, index: int) -> Optional[SwitchInput]:
        return self._switches.get(index)

    def all_dali(self)     -> List[DaliChannel]:  return list(self._dali.values())
    def all_relays(self)   -> List[WallRelay]:    return list(self._relays.values())
    def all_switches(self) -> List[SwitchInput]:  return list(self._switches.values())

    def rooms(self) -> List[str]:
        seen, result = set(), []
        for d in (*self._dali.values(), *self._relays.values()):
            if d.room not in seen:
                seen.add(d.room)
                result.append(d.room)
        return result

    @property
    def mock(self) -> bool:
        return self._client.mock

    @property
    def connected(self) -> bool:
        return self._client.is_connected

    # ── Bulk state read ───────────────────────────────────────────────────────

    def read_full_state(self) -> dict:
        """
        Returns the complete system state in one dict.
        Used by GET /plc/state/ for efficient polling.
        """
        dali_levels, relay_states, switch_states = {}, {}, {}

        for ch, dev in self._dali.items():
            try:
                dali_levels[ch] = dev.read_actual_level()
            except Exception as exc:
                logger.error("DALI ch%d read error: %s", ch, exc)
                dali_levels[ch] = None

        for ch, dev in self._relays.items():
            try:
                relay_states[ch] = dev.read_state()
            except Exception as exc:
                logger.error("Relay ch%d read error: %s", ch, exc)
                relay_states[ch] = None

        for idx, dev in self._switches.items():
            try:
                switch_states[idx] = dev.read_state()
            except Exception as exc:
                logger.error("Switch %d read error: %s", idx, exc)
                switch_states[idx] = None

        return {
            'mock':          self._client.mock,
            'dali':          dali_levels,
            'relays':        relay_states,
            'switches':      switch_states,
        }

    # ── Singleton ─────────────────────────────────────────────────────────────

    @classmethod
    def instance(cls) -> 'DeviceRegistry':
        with cls._instance_lock:
            if cls._instance is None:
                inst = cls()
                inst._start()
                cls._instance = inst
            return cls._instance
