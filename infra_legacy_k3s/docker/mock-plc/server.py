"""
Lugh Mock Beckhoff CX PLC Server
=================================
Emulates a real Beckhoff CX TwinCAT 3 controller over the ADS protocol.

Full variable map matches the real TwinCAT project exactly:

LIGHTING (gvlDALI)
  aPyLevel[1..28]          BYTE   0-254  desired brightness (Python→PLC)
  aPySetLevel[1..28]       BOOL          commit edge        (Python→PLC)
  aPyActualLevel[1..28]    BYTE   0-254  confirmed readback (PLC→Python)
  aPyWallRelay[1..4]       BOOL          relay command      (Python→PLC)
  aPyWallRelayState[1..4]  BOOL          relay readback     (PLC→Python)
  aPySwitchState[1..48]    BOOL          push-button state  (PLC→Python)

I/O — CURTAINS & APPLIANCES (gvlIO)
  aPyCurtainCmd[1..16]     BYTE  0=stop 1=open 2=close
  aPyCurtainState[1..16]   BYTE  0=unknown 1=open 2=closed 3=moving
  bPyFridgeCmd / State     BOOL
  bPyCoffeeMachineCmd/State BOOL
  bPyMicrowaveCmd / State  BOOL
  bPyOvenCmd / State       BOOL
  bPyGarageCmd / State     BOOL  (motorized garage door)

SECURITY (gvlIO)
  aPyDoorSensor[1..16]     BOOL  TRUE=open
  aPyWindowSensor[1..16]   BOOL  TRUE=open
  aPyMotionSensor[1..8]    BOOL  TRUE=motion detected
  bPyAlarmArm / State      BOOL
  bPyLockdown / State      BOOL
  bPyAlarmTriggered        BOOL
  bPyKeySwitch             BOOL  physical override key
  bPyDoorbellPressed       BOOL
  bPyDoorLock[1..4]        BOOL  electric strike state

HVAC (gvlHVAC)
  nPyThermostatSet[1..4]   REAL  °C setpoint per zone
  nPyThermostatActual[1..4] REAL °C measured temperature
  nPyHumidity[1..4]        REAL  %RH measured humidity
  nPyHVACMode[1..4]        BYTE  0=off 1=heat 2=cool 3=fan_only 4=auto
  nPyFanSpeed[1..4]        BYTE  0=auto 1=low 2=med 3=high
  bPyHVACOn[1..4]          BOOL  zone on/off master

FIRE & SAFETY (gvlSafety)
  bPySmokeSensor[1..8]     BOOL  TRUE=smoke detected
  bPyFireAlarm             BOOL  system-level fire alarm active
  bPySprinklerActive       BOOL  sprinkler triggered
  bPyGasSensor[1..4]       BOOL  TRUE=gas leak detected
  bPyGasShutoff            BOOL  master gas shutoff state
  bPyWaterLeakSensor[1..8] BOOL  TRUE=water detected
  bPyWaterShutoff          BOOL  master water shutoff state
  nPyCO2Level              REAL  ppm CO2 (air quality)

ENERGY (gvlEnergy)
  nPyPowerTotal            REAL  W  whole-apartment live power
  nPyEnergyDaily           REAL  kWh day-running total
  nPyEnergyMonthly         REAL  kWh month-running total
  nPyPowerCircuit[1..8]    REAL  W  per-circuit live power
  nPyCurrentCircuit[1..8]  REAL  A  per-circuit current
  nPyVoltage               REAL  V  mains voltage
  nPyFrequency             REAL  Hz mains frequency
  bPyCircuitBreaker[1..8]  BOOL  FALSE=tripped

WEATHER / ENVIRONMENT (gvlWeather)
  nPyOutdoorTemp           REAL  deg C
  nPyOutdoorHumidity       REAL  %RH
  nPyWindSpeed             REAL  m/s
  nPyWindDir               REAL  degrees (0=N)
  nPyRainfall              REAL  mm/h
  nPyUVIndex               REAL  0-11
  bPyRaining               BOOL

AUDIO (gvlAudio)
  nPyAudioVolume[1..4]     BYTE  0-100  zone volume
  nPyAudioSource[1..4]     BYTE  0=off 1=stream 2=line_in 3=bluetooth 4=tv_arc
  bPyAudioOn[1..4]         BOOL  zone on/off
  nPyAudioZoneGroup[1..4]  BYTE  grouping: zones with same non-zero value are linked

VIDEO / CAMERAS (gvlVideo)
  bPyCameraOn[1..4]        BOOL  camera active
  bPyCameraMotion[1..4]    BOOL  motion event from camera
  bPyTVOn[1..2]            BOOL  smart TV on/off
  nPyTVInput[1..2]         BYTE  0=hdmi1 1=hdmi2 2=cast 3=off

INTERCOM / DOORBIRD (gvlIntercom)
  bPyDoorbirdCallActive    BOOL  active SIP call from door station
  bPyDoorbirdRelayCmd      BOOL  open door command to DoorBird relay
  bPyDoorbirdMotion        BOOL  DoorBird PIR motion detection
  nPyDoorbirdSnapshot      BYTE  increments on each new snapshot frame
  bPyIntercomCallActive    BOOL  internal intercom call active
  bPyIntercomAnswer        BOOL  resident answered call

Exposes:
  ADS TCP server on ADS_PORT (default 48898)
  HTTP management API on HTTP_PORT (default 8080)

Simulation:
  A background thread runs at ~2 Hz and updates sensor readings with
  realistic random walks -- temperature drift, power consumption changes,
  occasional motion events, weather variation, etc.

Switching to a real PLC:
  Set PLC_MOCK=false in Django env and PLC_IP to the real CX IP.
  No changes to Django or this service are required.
"""
from __future__ import annotations

import json
import logging
import math
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s [mock-plc] %(message)s",
)
logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────────────

ADS_PORT       = int(os.getenv("ADS_PORT",      "48898"))
HTTP_PORT      = int(os.getenv("HTTP_PORT",     "8080"))
DALI_CHANNELS  = int(os.getenv("DALI_CHANNELS", "28"))
RELAY_CHANNELS = int(os.getenv("RELAY_CHANNELS","4"))
SIM_INTERVAL   = float(os.getenv("SIM_INTERVAL","0.5"))  # simulation tick in seconds

# ── In-memory PLC state ───────────────────────────────────────────────────────

_state_lock = threading.Lock()
_state: Dict[str, Any] = {}


def _init_state() -> None:
    global _state
    s: Dict[str, Any] = {}

    # ── DALI Lighting ──────────────────────────────────────────────────────────
    for i in range(1, DALI_CHANNELS + 1):
        s[f"gvlDALI.aPyLevel[{i}]"]       = 0
        s[f"gvlDALI.aPySetLevel[{i}]"]    = False
        s[f"gvlDALI.aPyActualLevel[{i}]"] = 0

    for i in range(1, RELAY_CHANNELS + 1):
        s[f"gvlDALI.aPyWallRelay[{i}]"]      = False
        s[f"gvlDALI.aPyWallRelayState[{i}]"] = False

    for i in range(1, 49):
        s[f"gvlDALI.aPySwitchState[{i}]"] = False

    # ── Curtains ───────────────────────────────────────────────────────────────
    for i in range(1, 17):
        s[f"gvlIO.aPyCurtainCmd[{i}]"]   = 0
        s[f"gvlIO.aPyCurtainState[{i}]"] = 2  # 2 = closed (default)

    # ── Appliances ─────────────────────────────────────────────────────────────
    for name in ("Fridge", "CoffeeMachine", "Microwave", "Oven"):
        s[f"gvlIO.bPy{name}Cmd"]   = False
        s[f"gvlIO.bPy{name}State"] = False
    s["gvlIO.bPyFridgeState"] = True   # fridge always on
    s["gvlIO.bPyGarageCmd"]   = False
    s["gvlIO.bPyGarageState"] = False  # False = closed

    # ── Door / window sensors ──────────────────────────────────────────────────
    for i in range(1, 17):
        s[f"gvlIO.aPyDoorSensor[{i}]"]   = False
        s[f"gvlIO.aPyWindowSensor[{i}]"] = False

    # ── Electric door locks ────────────────────────────────────────────────────
    for i in range(1, 5):
        s[f"gvlIO.bPyDoorLock[{i}]"] = True  # True = locked

    # ── PIR motion sensors ─────────────────────────────────────────────────────
    for i in range(1, 9):
        s[f"gvlIO.aPyMotionSensor[{i}]"] = False

    # ── Security ───────────────────────────────────────────────────────────────
    s["gvlIO.bPyAlarmArm"]        = False
    s["gvlIO.bPyAlarmState"]      = False
    s["gvlIO.bPyAlarmTriggered"]  = False
    s["gvlIO.bPyLockdown"]        = False
    s["gvlIO.bPyLockdownState"]   = False
    s["gvlIO.bPyKeySwitch"]       = False
    s["gvlIO.bPyDoorbellPressed"] = False

    # ── HVAC (4 zones: Living, Kitchen, Bedroom 1, Bedroom 2) ─────────────────
    for i in range(1, 5):
        s[f"gvlHVAC.nPyThermostatSet[{i}]"]    = 21.0
        s[f"gvlHVAC.nPyThermostatActual[{i}]"] = 21.0 + random.uniform(-1.5, 1.5)
        s[f"gvlHVAC.nPyHumidity[{i}]"]         = 45.0 + random.uniform(-5.0, 5.0)
        s[f"gvlHVAC.nPyHVACMode[{i}]"]         = 0    # 0=off
        s[f"gvlHVAC.nPyFanSpeed[{i}]"]         = 0    # 0=auto
        s[f"gvlHVAC.bPyHVACOn[{i}]"]           = False

    # ── Fire & Safety ──────────────────────────────────────────────────────────
    for i in range(1, 9):
        s[f"gvlSafety.bPySmokeSensor[{i}]"]    = False
        s[f"gvlSafety.bPyWaterLeakSensor[{i}]"]= False
    for i in range(1, 5):
        s[f"gvlSafety.bPyGasSensor[{i}]"]      = False
    s["gvlSafety.bPyFireAlarm"]       = False
    s["gvlSafety.bPySprinklerActive"] = False
    s["gvlSafety.bPyGasShutoff"]      = False
    s["gvlSafety.bPyWaterShutoff"]    = False
    s["gvlSafety.nPyCO2Level"]        = 420.0  # typical outdoor CO2

    # ── Energy ────────────────────────────────────────────────────────────────
    s["gvlEnergy.nPyPowerTotal"]    = 350.0   # W baseline
    s["gvlEnergy.nPyEnergyDaily"]   = 0.0
    s["gvlEnergy.nPyEnergyMonthly"] = 0.0
    s["gvlEnergy.nPyVoltage"]       = 230.0
    s["gvlEnergy.nPyFrequency"]     = 50.0
    for i in range(1, 9):
        s[f"gvlEnergy.nPyPowerCircuit[{i}]"]   = 0.0
        s[f"gvlEnergy.nPyCurrentCircuit[{i}]"] = 0.0
        s[f"gvlEnergy.bPyCircuitBreaker[{i}]"] = True   # True = healthy

    # ── Weather ───────────────────────────────────────────────────────────────
    s["gvlWeather.nPyOutdoorTemp"]     = 18.0
    s["gvlWeather.nPyOutdoorHumidity"] = 65.0
    s["gvlWeather.nPyWindSpeed"]       = 3.0
    s["gvlWeather.nPyWindDir"]         = 225.0   # SW
    s["gvlWeather.nPyRainfall"]        = 0.0
    s["gvlWeather.nPyUVIndex"]         = 3.0
    s["gvlWeather.bPyRaining"]         = False

    # ── Audio (4 zones: Living, Dining/Kitchen, Bedroom 1, Bedroom 2) ─────────
    for i in range(1, 5):
        s[f"gvlAudio.nPyAudioVolume[{i}]"]    = 30
        s[f"gvlAudio.nPyAudioSource[{i}]"]    = 0    # 0 = off
        s[f"gvlAudio.bPyAudioOn[{i}]"]        = False
        s[f"gvlAudio.nPyAudioZoneGroup[{i}]"] = 0    # ungrouped

    # ── Video / Cameras ───────────────────────────────────────────────────────
    for i in range(1, 5):
        s[f"gvlVideo.bPyCameraOn[{i}]"]     = True
        s[f"gvlVideo.bPyCameraMotion[{i}]"] = False
    for i in range(1, 3):
        s[f"gvlVideo.bPyTVOn[{i}]"]    = False
        s[f"gvlVideo.nPyTVInput[{i}]"] = 3   # 3 = off

    # ── Intercom / DoorBird ───────────────────────────────────────────────────
    s["gvlIntercom.bPyDoorbirdCallActive"] = False
    s["gvlIntercom.bPyDoorbirdRelayCmd"]   = False
    s["gvlIntercom.bPyDoorbirdMotion"]     = False
    s["gvlIntercom.nPyDoorbirdSnapshot"]   = 0
    s["gvlIntercom.bPyIntercomCallActive"] = False
    s["gvlIntercom.bPyIntercomAnswer"]     = False

    _state = s


_init_state()


# ── State accessors ───────────────────────────────────────────────────────────

def get_var(name: str) -> Any:
    with _state_lock:
        return _state.get(name)


def set_var(name: str, value: Any) -> bool:
    with _state_lock:
        if name not in _state:
            return False
        _state[name] = value
        _mirror_state(name, value)
        return True


def _mirror_state(name: str, value: Any) -> None:
    """Mirror write commands to their readback variables (simulates PLC CFC logic)."""

    # DALI: aPySetLevel[N]=True -> capture aPyLevel[N] into aPyActualLevel[N]
    if name.startswith("gvlDALI.aPySetLevel[") and value is True:
        ch = name.split("[")[1].rstrip("]")
        level = _state.get(f"gvlDALI.aPyLevel[{ch}]", 0)
        _state[f"gvlDALI.aPyActualLevel[{ch}]"] = level

    elif name.startswith("gvlDALI.aPyWallRelay["):
        ch = name.split("[")[1].rstrip("]")
        _state[f"gvlDALI.aPyWallRelayState[{ch}]"] = value

    elif name.endswith("Cmd") and "gvlIO.bPy" in name:
        state_key = name.replace("Cmd", "State")
        if state_key in _state:
            _state[state_key] = value

    elif name.startswith("gvlIO.aPyCurtainCmd["):
        idx = name.split("[")[1].rstrip("]")
        if value in (1, 2):
            _state[f"gvlIO.aPyCurtainState[{idx}]"] = value

    elif name == "gvlIO.bPyAlarmArm":
        _state["gvlIO.bPyAlarmState"] = value

    elif name == "gvlIO.bPyLockdown":
        _state["gvlIO.bPyLockdownState"] = value

    elif name.startswith("gvlAudio.nPyAudioSource["):
        idx = name.split("[")[1].rstrip("]")
        _state[f"gvlAudio.bPyAudioOn[{idx}]"] = (value != 0)

    elif name == "gvlIntercom.bPyDoorbirdRelayCmd" and value is True:
        # Auto-reset relay after 1 s pulse
        def _reset() -> None:
            time.sleep(1.0)
            with _state_lock:
                _state["gvlIntercom.bPyDoorbirdRelayCmd"] = False
        threading.Thread(target=_reset, daemon=True).start()


def get_all_state() -> Dict[str, Any]:
    with _state_lock:
        return dict(_state)


# ── Realistic simulation loop ─────────────────────────────────────────────────

_sim_tick   = 0
_energy_acc = 0.0   # Wh accumulator for daily kWh total


def _simulate() -> None:
    """Background simulation thread — runs every SIM_INTERVAL seconds."""
    while True:
        time.sleep(SIM_INTERVAL)
        _run_simulation_tick()


def _run_simulation_tick() -> None:
    global _sim_tick, _energy_acc
    _sim_tick += 1

    with _state_lock:
        now = time.time()

        # ── Temperature / humidity drift ───────────────────────────────────────
        for i in range(1, 5):
            actual = _state[f"gvlHVAC.nPyThermostatActual[{i}]"]
            setpt  = _state[f"gvlHVAC.nPyThermostatSet[{i}]"]
            on     = _state[f"gvlHVAC.bPyHVACOn[{i}]"]
            mode   = _state[f"gvlHVAC.nPyHVACMode[{i}]"]

            if on and mode in (1, 2, 4):
                drift = (1 if setpt > actual else -1) * 0.05
            else:
                drift = (19.0 - actual) * 0.002 + random.gauss(0, 0.02)

            _state[f"gvlHVAC.nPyThermostatActual[{i}]"] = round(actual + drift, 2)
            hum = _state[f"gvlHVAC.nPyHumidity[{i}]"]
            _state[f"gvlHVAC.nPyHumidity[{i}]"] = round(
                max(20.0, min(90.0, hum + random.gauss(0, 0.1))), 1
            )

        # ── CO2 drift ──────────────────────────────────────────────────────────
        motions = sum(
            1 for i in range(1, 9)
            if _state.get(f"gvlIO.aPyMotionSensor[{i}]")
        )
        co2 = _state["gvlSafety.nPyCO2Level"]
        co2 += motions * 1.5 - 0.5
        _state["gvlSafety.nPyCO2Level"] = round(max(380.0, min(2000.0, co2)), 1)

        # ── Energy ─────────────────────────────────────────────────────────────
        total_w = 80.0  # standby baseline

        for i in range(1, DALI_CHANNELS + 1):
            lvl = _state.get(f"gvlDALI.aPyActualLevel[{i}]", 0)
            total_w += (lvl / 254.0) * 18.0

        if _state.get("gvlIO.bPyFridgeState"):         total_w += 120
        if _state.get("gvlIO.bPyCoffeeMachineState"):  total_w += 1200
        if _state.get("gvlIO.bPyMicrowaveState"):      total_w += 1000
        if _state.get("gvlIO.bPyOvenState"):           total_w += 2200
        for i in range(1, 5):
            if _state.get(f"gvlHVAC.bPyHVACOn[{i}]"): total_w += 800

        total_w = max(0.0, total_w + random.gauss(0, 15))
        _state["gvlEnergy.nPyPowerTotal"] = round(total_w, 1)
        _state["gvlEnergy.nPyVoltage"]    = round(230.0 + random.gauss(0, 0.5), 1)
        _state["gvlEnergy.nPyFrequency"]  = round(50.0 + random.gauss(0, 0.01), 2)

        fracs = [0.18, 0.15, 0.14, 0.12, 0.13, 0.11, 0.09, 0.08]
        for i, frac in enumerate(fracs, start=1):
            cw = max(0.0, total_w * frac + random.gauss(0, 5))
            _state[f"gvlEnergy.nPyPowerCircuit[{i}]"]   = round(cw, 1)
            _state[f"gvlEnergy.nPyCurrentCircuit[{i}]"] = round(cw / 230.0, 3)

        _energy_acc += total_w * SIM_INTERVAL / 3600.0
        _state["gvlEnergy.nPyEnergyDaily"] = round(_energy_acc / 1000.0, 4)

        # ── Weather ────────────────────────────────────────────────────────────
        day_frac = (now % 86400) / 86400.0
        base_temp = 15.0 + 8.0 * math.sin(2 * math.pi * (day_frac - 0.25))
        _state["gvlWeather.nPyOutdoorTemp"] = round(
            base_temp + random.gauss(0, 0.3), 1
        )
        hum = _state["gvlWeather.nPyOutdoorHumidity"]
        _state["gvlWeather.nPyOutdoorHumidity"] = round(
            max(20.0, min(99.0, hum + random.gauss(0, 0.2))), 1
        )
        ws = _state["gvlWeather.nPyWindSpeed"]
        _state["gvlWeather.nPyWindSpeed"] = round(
            max(0.0, ws + random.gauss(0, 0.1)), 1
        )
        uv = max(0.0, 7.0 * math.sin(math.pi * day_frac)) if 0.25 < day_frac < 0.75 else 0.0
        _state["gvlWeather.nPyUVIndex"] = round(max(0.0, uv + random.gauss(0, 0.1)), 1)

        if random.random() < 0.0005:
            _state["gvlWeather.bPyRaining"] = not _state["gvlWeather.bPyRaining"]
        if _state["gvlWeather.bPyRaining"]:
            rf = _state["gvlWeather.nPyRainfall"]
            _state["gvlWeather.nPyRainfall"] = round(
                max(0.0, rf + random.gauss(0.5, 0.2)), 1
            )
        else:
            _state["gvlWeather.nPyRainfall"] = 0.0

        # ── Motion (sparse random events + auto-clear) ─────────────────────────
        if random.random() < 0.008:
            idx = random.randint(1, 8)
            _state[f"gvlIO.aPyMotionSensor[{idx}]"] = True
        for i in range(1, 9):
            if _state.get(f"gvlIO.aPyMotionSensor[{i}]") and random.random() < 0.05:
                _state[f"gvlIO.aPyMotionSensor[{i}]"] = False

        # ── DoorBird motion (very sparse) ──────────────────────────────────────
        if random.random() < 0.002:
            _state["gvlIntercom.bPyDoorbirdMotion"] = True
        elif _state.get("gvlIntercom.bPyDoorbirdMotion") and random.random() < 0.1:
            _state["gvlIntercom.bPyDoorbirdMotion"] = False

        # ── Camera motion flickers ─────────────────────────────────────────────
        for i in range(1, 5):
            if _state.get(f"gvlVideo.bPyCameraOn[{i}]"):
                if random.random() < 0.003:
                    _state[f"gvlVideo.bPyCameraMotion[{i}]"] = True
                elif _state.get(f"gvlVideo.bPyCameraMotion[{i}]") and random.random() < 0.15:
                    _state[f"gvlVideo.bPyCameraMotion[{i}]"] = False


# ── ADS Server ────────────────────────────────────────────────────────────────

def _start_ads_server() -> Any:
    """
    Start the ADS TCP mock server using pyads testserver.

    Django connects to this exactly as it would to a real Beckhoff CX.
    Falls back gracefully if pyads is unavailable.
    """
    try:
        import pyads
        from pyads import testserver

        symbols: dict = {}

        for i in range(1, DALI_CHANNELS + 1):
            symbols[f"gvlDALI.aPyLevel[{i}]"]       = (pyads.PLCTYPE_USINT, 0)
            symbols[f"gvlDALI.aPySetLevel[{i}]"]    = (pyads.PLCTYPE_BOOL, False)
            symbols[f"gvlDALI.aPyActualLevel[{i}]"] = (pyads.PLCTYPE_USINT, 0)
        for i in range(1, RELAY_CHANNELS + 1):
            symbols[f"gvlDALI.aPyWallRelay[{i}]"]      = (pyads.PLCTYPE_BOOL, False)
            symbols[f"gvlDALI.aPyWallRelayState[{i}]"] = (pyads.PLCTYPE_BOOL, False)
        for i in range(1, 49):
            symbols[f"gvlDALI.aPySwitchState[{i}]"] = (pyads.PLCTYPE_BOOL, False)

        for i in range(1, 17):
            symbols[f"gvlIO.aPyCurtainCmd[{i}]"]   = (pyads.PLCTYPE_USINT, 0)
            symbols[f"gvlIO.aPyCurtainState[{i}]"] = (pyads.PLCTYPE_USINT, 2)
            symbols[f"gvlIO.aPyDoorSensor[{i}]"]   = (pyads.PLCTYPE_BOOL, False)
            symbols[f"gvlIO.aPyWindowSensor[{i}]"] = (pyads.PLCTYPE_BOOL, False)
        for i in range(1, 9):
            symbols[f"gvlIO.aPyMotionSensor[{i}]"] = (pyads.PLCTYPE_BOOL, False)
        for i in range(1, 5):
            symbols[f"gvlIO.bPyDoorLock[{i}]"] = (pyads.PLCTYPE_BOOL, True)
        for n in ("Fridge", "CoffeeMachine", "Microwave", "Oven"):
            symbols[f"gvlIO.bPy{n}Cmd"]   = (pyads.PLCTYPE_BOOL, False)
            symbols[f"gvlIO.bPy{n}State"] = (pyads.PLCTYPE_BOOL, False)
        for n in ("AlarmArm", "AlarmState", "AlarmTriggered", "Lockdown",
                  "LockdownState", "KeySwitch", "DoorbellPressed",
                  "GarageCmd", "GarageState"):
            symbols[f"gvlIO.bPy{n}"] = (pyads.PLCTYPE_BOOL, False)

        for i in range(1, 5):
            symbols[f"gvlHVAC.nPyThermostatSet[{i}]"]    = (pyads.PLCTYPE_REAL, 21.0)
            symbols[f"gvlHVAC.nPyThermostatActual[{i}]"] = (pyads.PLCTYPE_REAL, 21.0)
            symbols[f"gvlHVAC.nPyHumidity[{i}]"]         = (pyads.PLCTYPE_REAL, 45.0)
            symbols[f"gvlHVAC.nPyHVACMode[{i}]"]         = (pyads.PLCTYPE_USINT, 0)
            symbols[f"gvlHVAC.nPyFanSpeed[{i}]"]         = (pyads.PLCTYPE_USINT, 0)
            symbols[f"gvlHVAC.bPyHVACOn[{i}]"]           = (pyads.PLCTYPE_BOOL, False)

        for i in range(1, 9):
            symbols[f"gvlSafety.bPySmokeSensor[{i}]"]     = (pyads.PLCTYPE_BOOL, False)
            symbols[f"gvlSafety.bPyWaterLeakSensor[{i}]"] = (pyads.PLCTYPE_BOOL, False)
        for i in range(1, 5):
            symbols[f"gvlSafety.bPyGasSensor[{i}]"] = (pyads.PLCTYPE_BOOL, False)
        for n in ("FireAlarm", "SprinklerActive", "GasShutoff", "WaterShutoff"):
            symbols[f"gvlSafety.bPy{n}"] = (pyads.PLCTYPE_BOOL, False)
        symbols["gvlSafety.nPyCO2Level"] = (pyads.PLCTYPE_REAL, 420.0)

        for n in ("PowerTotal", "EnergyDaily", "EnergyMonthly", "Voltage", "Frequency"):
            symbols[f"gvlEnergy.nPy{n}"] = (pyads.PLCTYPE_REAL, 0.0)
        for i in range(1, 9):
            symbols[f"gvlEnergy.nPyPowerCircuit[{i}]"]   = (pyads.PLCTYPE_REAL, 0.0)
            symbols[f"gvlEnergy.nPyCurrentCircuit[{i}]"] = (pyads.PLCTYPE_REAL, 0.0)
            symbols[f"gvlEnergy.bPyCircuitBreaker[{i}]"] = (pyads.PLCTYPE_BOOL, True)

        for n in ("OutdoorTemp", "OutdoorHumidity", "WindSpeed",
                  "WindDir", "Rainfall", "UVIndex"):
            symbols[f"gvlWeather.nPy{n}"] = (pyads.PLCTYPE_REAL, 0.0)
        symbols["gvlWeather.bPyRaining"] = (pyads.PLCTYPE_BOOL, False)

        for i in range(1, 5):
            symbols[f"gvlAudio.nPyAudioVolume[{i}]"]    = (pyads.PLCTYPE_USINT, 30)
            symbols[f"gvlAudio.nPyAudioSource[{i}]"]    = (pyads.PLCTYPE_USINT, 0)
            symbols[f"gvlAudio.bPyAudioOn[{i}]"]        = (pyads.PLCTYPE_BOOL, False)
            symbols[f"gvlAudio.nPyAudioZoneGroup[{i}]"] = (pyads.PLCTYPE_USINT, 0)

        for i in range(1, 5):
            symbols[f"gvlVideo.bPyCameraOn[{i}]"]     = (pyads.PLCTYPE_BOOL, True)
            symbols[f"gvlVideo.bPyCameraMotion[{i}]"] = (pyads.PLCTYPE_BOOL, False)
        for i in range(1, 3):
            symbols[f"gvlVideo.bPyTVOn[{i}]"]    = (pyads.PLCTYPE_BOOL, False)
            symbols[f"gvlVideo.nPyTVInput[{i}]"] = (pyads.PLCTYPE_USINT, 3)

        for n in ("DoorbirdCallActive", "DoorbirdRelayCmd", "DoorbirdMotion",
                  "IntercomCallActive", "IntercomAnswer"):
            symbols[f"gvlIntercom.bPy{n}"] = (pyads.PLCTYPE_BOOL, False)
        symbols["gvlIntercom.nPyDoorbirdSnapshot"] = (pyads.PLCTYPE_USINT, 0)

        handler = testserver.AdsTestServerHandler()
        for sym_name, (sym_type, default) in symbols.items():
            handler.add_variable(testserver.PLCVariable(sym_name, default, sym_type))

        server = testserver.AdsTestServer(
            handler=handler, ip_address="0.0.0.0", port=ADS_PORT,
        )
        logger.info("ADS server starting on port %d (%d symbols)", ADS_PORT, len(symbols))
        server.start()
        logger.info("ADS server running (pyads testserver)")
        return server

    except Exception as exc:
        logger.warning(
            "pyads testserver unavailable (%s). "
            "Django must use PLC_MOCK=true. HTTP management API still available.",
            exc,
        )
        return None


# ── HTTP Management API ────────────────────────────────────────────────────────

class MockPLCHandler(BaseHTTPRequestHandler):
    """Lightweight HTTP API for state inspection, injection, and reset."""

    def log_message(self, fmt, *args) -> None:
        logger.debug("HTTP %s", fmt % args)

    def _send_json(self, code: int, data: Any) -> None:
        body = json.dumps(data, indent=2, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(200, {
                "status": "ok",
                "service": "lugh-mock-plc",
                "variables": len(_state),
                "sim_tick": _sim_tick,
            })

        elif self.path == "/state":
            self._send_json(200, {
                "ok": True,
                "state": get_all_state(),
                "timestamp": time.time(),
            })

        elif self.path.startswith("/state/"):
            prefix = self.path[7:]
            with _state_lock:
                subset = {k: v for k, v in _state.items() if k.startswith(prefix)}
            self._send_json(200, {"ok": True, "prefix": prefix, "state": subset})

        elif self.path.startswith("/var/"):
            name = self.path[5:]
            val  = get_var(name)
            if val is None:
                self._send_json(404, {"ok": False, "error": f"Unknown: {name}"})
            else:
                self._send_json(200, {"ok": True, "name": name, "value": val})

        elif self.path == "/vars":
            with _state_lock:
                keys = sorted(_state.keys())
            self._send_json(200, {"ok": True, "count": len(keys), "variables": keys})

        elif self.path == "/simulate/tick":
            _run_simulation_tick()
            self._send_json(200, {"ok": True, "message": "Simulation tick executed"})

        else:
            self._send_json(404, {"error": "Not found"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        body   = self.rfile.read(length)

        if self.path == "/reset":
            _init_state()
            self._send_json(200, {"ok": True, "message": "State reset to defaults"})
            logger.info("State reset via HTTP API")
            return

        if self.path == "/simulate/trigger_alarm":
            with _state_lock:
                _state["gvlSafety.bPyFireAlarm"]       = True
                _state["gvlSafety.bPySmokeSensor[1]"]  = True
                _state["gvlIO.bPyAlarmTriggered"]       = True
            self._send_json(200, {"ok": True, "message": "Fire alarm triggered"})
            return

        if self.path == "/simulate/doorbell":
            with _state_lock:
                _state["gvlIO.bPyDoorbellPressed"]            = True
                _state["gvlIntercom.bPyDoorbirdCallActive"]   = True
            def _reset() -> None:
                time.sleep(2.0)
                with _state_lock:
                    _state["gvlIO.bPyDoorbellPressed"]           = False
                    _state["gvlIntercom.bPyDoorbirdCallActive"]  = False
            threading.Thread(target=_reset, daemon=True).start()
            self._send_json(200, {"ok": True, "message": "Doorbell (auto-resets in 2 s)"})
            return

        if self.path.startswith("/var/"):
            name = self.path[5:]
            try:
                payload = json.loads(body)
                value   = payload.get("value")
                if set_var(name, value):
                    self._send_json(200, {"ok": True, "name": name, "value": value})
                else:
                    self._send_json(404, {"ok": False, "error": f"Unknown: {name}"})
            except (json.JSONDecodeError, KeyError) as exc:
                self._send_json(400, {"ok": False, "error": str(exc)})
            return

        self._send_json(404, {"error": "Not found"})


def _start_http_server() -> HTTPServer:
    server = HTTPServer(("0.0.0.0", HTTP_PORT), MockPLCHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    logger.info("HTTP management API on port %d", HTTP_PORT)
    return server


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    logger.info("=" * 64)
    logger.info("Lugh Mock Beckhoff CX PLC  --  full device simulation")
    logger.info("DALI channels : %d", DALI_CHANNELS)
    logger.info("Relay channels: %d", RELAY_CHANNELS)
    logger.info("Sim interval  : %.1f s", SIM_INTERVAL)
    logger.info("Total vars    : %d", len(_state))
    logger.info("=" * 64)

    _start_http_server()
    _start_ads_server()

    sim_thread = threading.Thread(target=_simulate, daemon=True)
    sim_thread.start()
    logger.info("Simulation loop started (%.1f Hz)", 1.0 / SIM_INTERVAL)
    logger.info("")
    logger.info("  GET  /health                     -- health check")
    logger.info("  GET  /state                      -- full state snapshot")
    logger.info("  GET  /state/<prefix>              -- filtered (e.g. /state/gvlHVAC)")
    logger.info("  GET  /vars                       -- list all variable names")
    logger.info("  GET  /var/<name>                 -- single variable value")
    logger.info("  POST /var/<name> {\"value\":x}     -- set a variable")
    logger.info("  POST /reset                      -- reset to defaults")
    logger.info("  POST /simulate/trigger_alarm     -- trigger fire alarm")
    logger.info("  POST /simulate/doorbell          -- simulate doorbell press")
    logger.info("  GET  /simulate/tick              -- execute one sim tick manually")

    try:
        while True:
            time.sleep(30)
            with _state_lock:
                temp1 = _state.get("gvlHVAC.nPyThermostatActual[1]", 0.0)
                power = _state.get("gvlEnergy.nPyPowerTotal", 0.0)
            logger.debug(
                "Heartbeat -- tick=%d  zone1=%.1f C  power=%.0f W",
                _sim_tick, temp1, power,
            )
    except KeyboardInterrupt:
        logger.info("Shutting down mock PLC")
