"""
PLC device abstractions built on top of ADSClient.

Variable map (from gvlDALI in TwinCAT project):

  DALI dimmers (channel index 1-16):
    gvlDALI.aPyLevel[N]       BYTE  0-254   written by app  → target level
    gvlDALI.aPySetLevel[N]    BOOL          written by app  → rising edge commits level
    gvlDALI.aPyActualLevel[N] BYTE  0-254   written by PLC  → readback

  Wall relays (channel index 1-4):
    gvlDALI.aPyWallRelay[N]      BOOL   written by app → relay command
    gvlDALI.aPyWallRelayState[N] BOOL   written by PLC → readback

  Switch inputs (index 1-40, BTicino L4036 via KL1809):
    gvlDALI.aSwitch[N]           BOOL   written by PLC → physical button state

Protocol for setting a DALI channel:
  1. write aPyLevel[N]    = target (0-254)
  2. write aPySetLevel[N] = True   (rising edge → PLC captures level)
  3. short delay (~50 ms)
  4. write aPySetLevel[N] = False  (reset for next command)
"""
from __future__ import annotations

import logging
import random
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import pyads

logger = logging.getLogger(__name__)

# DALI percent ↔ byte helpers (0-100 % ↔ 0-254 BYTE)
def pct_to_byte(pct: int) -> int:
    return int(max(0, min(100, pct)) / 100 * 254)

def byte_to_pct(b: int) -> int:
    return round(max(0, min(254, b)) / 254 * 100)


# ── DaliChannel ───────────────────────────────────────────────────────────────

class DaliChannel:
    """
    Single DALI dimmer channel.

    channel: 1-16 (matches DALI short address / PLC array index)
    """

    def __init__(self, channel: int, name: str, room: str, client):
        if not 1 <= channel <= 16:
            raise ValueError(f"DALI channel must be 1-16, got {channel}")
        self.channel = channel
        self.name    = name
        self.room    = room
        self._client = client

        # Mock state
        self._mock_level:  int  = 0          # 0-254
        self._mock_switch: bool = False      # shared switch input mock

    # ── PLC variable names ────────────────────────────────────────────────────

    @property
    def _var_level(self) -> str:
        return f'gvlDALI.aPyLevel[{self.channel}]'

    @property
    def _var_set_level(self) -> str:
        return f'gvlDALI.aPySetLevel[{self.channel}]'

    @property
    def _var_actual(self) -> str:
        return f'gvlDALI.aPyActualLevel[{self.channel}]'

    # ── Control ───────────────────────────────────────────────────────────────

    def set_brightness(self, percent: int):
        """Set dimmer to 0-100 %. Fires rising edge on aPySetLevel."""
        level = pct_to_byte(percent)
        if self._client.mock:
            self._mock_level = level
            return
        self._client.write(self._var_level,     level, pyads.PLCTYPE_BYTE)
        self._client.write(self._var_set_level, True,  pyads.PLCTYPE_BOOL)
        time.sleep(0.05)
        self._client.write(self._var_set_level, False, pyads.PLCTYPE_BOOL)

    # ── State read ────────────────────────────────────────────────────────────

    def read_actual_level(self) -> int:
        """Returns actual brightness 0-100 %."""
        if self._client.mock:
            return byte_to_pct(self._mock_level)
        raw = self._client.read(self._var_actual, pyads.PLCTYPE_BYTE)
        return byte_to_pct(int(raw))

    def to_dict(self) -> Dict[str, Any]:
        return {
            'channel':     self.channel,
            'name':        self.name,
            'room':        self.room,
            'device_type': 'dali_light',
        }


# ── WallRelay ─────────────────────────────────────────────────────────────────

class WallRelay:
    """
    One of the 4 wall-light relay outputs driven by POU_WALLLIGHT.

    channel: 1-4 (maps to gvlDALI.aPyWallRelay[N])
    """

    def __init__(self, channel: int, name: str, room: str, client):
        if not 1 <= channel <= 4:
            raise ValueError(f"WallRelay channel must be 1-4, got {channel}")
        self.channel = channel
        self.name    = name
        self.room    = room
        self._client = client
        self._mock_state = False

    @property
    def _var_cmd(self) -> str:
        return f'gvlDALI.aPyWallRelay[{self.channel}]'

    @property
    def _var_state(self) -> str:
        return f'gvlDALI.aPyWallRelayState[{self.channel}]'

    def set_state(self, on: bool):
        if self._client.mock:
            self._mock_state = on
            return
        self._client.write(self._var_cmd, on, pyads.PLCTYPE_BOOL)

    def read_state(self) -> bool:
        if self._client.mock:
            return self._mock_state
        return bool(self._client.read(self._var_state, pyads.PLCTYPE_BOOL))

    def to_dict(self) -> Dict[str, Any]:
        return {
            'channel':     self.channel,
            'name':        self.name,
            'room':        self.room,
            'device_type': 'wall_relay',
        }


# ── SwitchInput ───────────────────────────────────────────────────────────────

class SwitchInput:
    """
    One BTicino L4036 pushbutton input (read-only).

    index: 1-40 (maps to gvlDALI.aSwitch[N], KL1809 EtherCAT terminal)
    """

    def __init__(self, index: int, name: str, room: str, client):
        if not 1 <= index <= 40:
            raise ValueError(f"Switch index must be 1-40, got {index}")
        self.index   = index
        self.name    = name
        self.room    = room
        self._client = client
        self._mock_state = False

    @property
    def _var(self) -> str:
        return f'gvlDALI.aSwitch[{self.index}]'

    def read_state(self) -> bool:
        if self._client.mock:
            # Occasionally simulate a press for testing
            if random.random() < 0.02:
                self._mock_state = not self._mock_state
            return self._mock_state
        return bool(self._client.read(self._var, pyads.PLCTYPE_BOOL))

    def to_dict(self) -> Dict[str, Any]:
        return {
            'index':       self.index,
            'name':        self.name,
            'room':        self.room,
            'device_type': 'switch_input',
        }
