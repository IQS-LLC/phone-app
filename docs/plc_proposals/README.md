# Proposed TwinCAT changes for real app control (Apartment 16)

**2026-08-24 update — the wall-relay half of this was superseded, and now
works.** After the revert described below, wall-relay *writes* were later
re-implemented through a different, isolated bridge GVL/POU
(`gvlController`/`POU_Controller`) that never touches `WallLight_POU` at
all — avoiding the exact conflict that caused the original outage. That
bridge is live today; see `find_device/plc/devices.py`'s `WallRelay` class
docstring for the real, current variable names. `django_side_status.md`'s
description of relay writes failing with `symbol not found` describes the
state *before* that later fix and is no longer accurate for relays — it's
kept below for the historical record and because the underlying lesson
(test wall-relay-scale and DALI-scale changes as separate build/download
cycles) still stands. **The DALI dimmer half described below is still
accurate** — DALI brightness channels are not wired into live PLC logic
today; see `docs/plc-integration.md`'s Hardware Support Matrix.

**Status: this wall-relay change (and the related DALI one) was applied,
built, and downloaded to the real CX8190 — and has since been reverted.**
The DALI proposal's `bOn` wiring (see `dali_dimmer_control.md`) broke
switch-driven lighting building-wide once live; all four touched PLC
source files, including this proposal's `WallLight_POU.TcPOU` /
`POU_GUEST_Bathroom.TcPOU` additions, were reverted together as a single
recovery action rather than surgically un-doing only the DALI piece. That
means the wall-relay change described below is currently *also* reverted
and *also* unverified on its own — it was never independently confirmed
safe in isolation before the DALI change was layered on top and broke
things. Re-apply and physically test this one alone, separately from any
DALI change, before trusting it again.

Two proposals, same root cause, same shape:
- **This file** — the 4 wall relays. Small, 4 channels, do this one first.
- **`dali_dimmer_control.md`** — the 30 DALI dimmer channels. Same fix
  pattern, bigger blast radius (30 channels instead of 4) — do this after
  the relay proposal is re-deployed and confirmed working on its own.

## Why (wall relays)

## Why

Confirmed by reading the actual deployed program
(`Apartmant16/TwinCAT DALI Sensor Project/DALI_PLC/POUs/WallLight_POU.TcPOU`):
today the 4 wall-light relays are driven **only** by the physical wall
switch (`gvlDALI.bSwitchOn30-33`) and the motion sensors (`gvlDALI.bSensor0-3`).
`gvlDALI.bRelay0-3` is written *by* the POU every scan cycle from internal
state — it is a readback, not a command input. There is currently no
variable the Django app can write to that the PLC program actually reads.
The Lugh app's `WallRelay.set_state()` in `find_device/plc/devices.py`
already reads real relay state correctly (`gvlDALI.bRelay0-3`), it just
has nothing to write to yet.

## What this adds

Two new BOOL variables per light in `gvlDALI` (8 total), and a few lines
in `WallLight_POU` that let a rising edge on `bPyRelaySetN` force
`bLightStateN` to whatever `bPyRelayCmdN` says — **purely additive**.
Nothing about the existing physical-switch or motion-sensor behavior
changes; the new block sits in the same place a physical button press
would land, so a resident's wall switch keeps working exactly as today,
and the app's command is just another way to flip the same internal state.

- `gvl_additions.txt` — new GVL declarations to add to `gvlDALI.TcGVL`
- `WallLight_POU_additions.md` — exact declaration + ST lines to add to
  `WallLight_POU.TcPOU`, per light, with placement instructions
- `django_side_status.md` — what's already updated on the Django side and
  what to change once this is deployed

## How to apply (for whoever has TwinCAT access)

1. Open `TwinCAT DALI Sensor Project` in TwinCAT XAE (Visual Studio).
2. Open `gvlDALI.TcGVL`, add the 8 declarations from `gvl_additions.txt`.
3. Open `WallLight_POU.TcPOU`, add one `R_TRIG` per light to the `VAR`
   block and one `IF` block per light to the ST implementation — exact
   text and placement in `WallLight_POU_additions.md`.
4. Build, activate configuration, download to the CX8190 in a maintenance
   window (this restarts the PLC task).
5. Verify: from an engineering PC connected to the CX, force
   `gvlDALI.bPyRelayCmd0 := TRUE` then pulse `bPyRelaySet0` and confirm
   Light 1 responds, exactly like pressing its wall switch would.
6. Tell me it's deployed — I'll switch `WallRelay.set_state()` from
   "documented as pending" to "expected to work" and re-verify end-to-end
   against the real device.

## What actually happened when this was applied

Building and downloading new PLC logic to a live CX8190 restarts its PLC
task and directly changes how real lights/relays in an occupied apartment
behave. That risk was explicitly accepted and this was applied directly —
the relay wiring above plus the DALI `bOn` wiring in the same
build/download. The DALI half broke switch-driven lighting building-wide;
everything was reverted together. Lesson for next time: apply and
physically verify wall-relay-scale (4 channel) and DALI-scale (30 channel)
changes as two separate build/download/test cycles, not one — a problem in
either one currently forces reverting both.
