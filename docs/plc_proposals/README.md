# Proposed TwinCAT change: app control of the 4 wall relays (Apartment 16)

**Status: proposal only. Nothing here has been applied to the real CX8190.**
Everything in this folder is a suggested addition for someone with TwinCAT
System Manager / XAE access (and authority to touch this live building
controller) to review, apply, build, and download themselves.

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

## Why I didn't do this myself

Building and downloading new PLC logic to a live CX8190 restarts its PLC
task and directly changes how real lights/relays in an occupied apartment
behave. That crosses into "requires the physical environment and a human
who owns that risk" — I can propose and verify the software side, but not
push new control logic to live building hardware without you (or whoever
owns this PLC) reviewing and deploying it.
