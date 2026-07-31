# TwinCAT change: Modbus TCP bridge (TF6250) alongside ADS

**Status: written to source in both repos, not yet built/downloaded to the
real CX8190, and TF6250 itself is not yet installed/licensed on the target.**
Nothing here has been physically verified. Django-side code defaults this
entirely off (`PLC_MODBUS_ENABLED` unset = `False`) so it has zero effect on
the working ADS connection until someone deliberately turns it on.

## Why

ADS/AMS has been the source of most of this project's connectivity pain —
route-table resets on rebuild/reactivate, Secure ADS friction, symbol-version
invalidation after a download. Modbus TCP has none of that: no AMS router, no
route table, no symbol versioning, just a flat register map over a plain TCP
socket. It exists specifically as a second path that survives the class of
failure ADS doesn't, not as a replacement — it has no symbol names, no
discovery, and only reaches the handful of points explicitly bridged below.

## PLC side (Apartmant16)

Two new, isolated files — same pattern as `gvlController`/`POU_Controller`
and `gvlCurtain`/`POU_Curtain`: nothing here edits `gvlDALI`, `gvlDALI_State`,
or any physical I/O wiring directly.

- **`GVLs/GVL.TcGVL`** — object name is fixed by TF6250's default
  `TcModbusSrv.xml` mapping (must be exactly `GVL`, not renameable). Declares
  the four arrays TF6250's server reads/writes directly:
  `mb_Output_Coils`, `mb_Input_Coils`, `mb_Output_Registers`, `mb_Input_Registers`.
- **`POUs/POU_Modbus.TcPOU`** — bridges those arrays to the existing
  `gvlController`/`gvlCurtain` app layer every scan. Called last from `MAIN`
  (after `POU_Curtain`).

### Register map

| Modbus memory | Index | PLC variable | Direction (master's view) |
|---|---|---|---|
| Input Registers | 0-15 | `gvlController.aDaliActual[1..16]` | read (DALI actual level, 0-254) |
| Holding Registers (`mb_Output_Registers`) | 0-15 | `gvlController.aDaliLevel[1..16]` + pulses `aDaliSetLevel[N]` on change | write (DALI set level, 0-254) |
| Discrete Inputs (`mb_Input_Coils`) | 0-3 | `gvlController.bRelayCmd0-3` | read (relay actual state) |
| Coils (`mb_Output_Coils`) | 0-3 | `gvlController.bRelayCmd0-3` + pulses `bRelaySet0-3` on change | write (relay commanded state) |
| Discrete Inputs (`mb_Input_Coils`) | 4-7 | `gvlCurtain.bCurtain{1,1,2,2}.{Open,Close}` | read (curtain output state) |
| Coils (`mb_Output_Coils`) | 4-7 | `gvlCurtain.bCurtain{1,1,2,2}.{Open,Close}Btn` | write (curtain button, held-while-true) |

DALI and relay writes are edge/change-detected in `POU_Modbus` (via `R_TRIG`
on a value-disagreement signal) so a Modbus write behaves identically to an
ADS/app write hitting the same rising-edge "commit" pins `POU_Controller`
already expects — see that POU's comments. Curtains are a direct level
passthrough, matching `POU_Curtain`'s own held-while-true button model.

Only 16 of `gvlController`'s 31 DALI channels and all 4 relays are bridged —
scoped to what's actually wired today (confirmed live: 16 DALI channels, 4
relays). Everything else (switches, sensors, appliances) has no Modbus path.

## What you still need to do, outside this project

1. **Install TF6250 (Modbus TCP)** on the CX8190. This device runs **TwinCAT
   CE7 on ARM**, not TwinCAT/BSD — use the CE-ARM package, not the BSD
   package repository instructions in Beckhoff's docs (they default to
   describing BSD). Confirmed CE-ARM is a supported platform for TF6250;
   the CX8190 specifically isn't named in what I could find, so verify
   against Beckhoff's product finder or support before relying on it.
2. **License it** — same 7-day-trial-or-purchase situation as the rest of
   TwinCAT here (there's already a `TrialLicense.tclrs` in this project).
3. **Configure the Modbus TCP Server instance** to point at the `GVL` object
   above (`TcModbusSrv.xml`, or the equivalent XAE config screen for
   whichever TF6250 version installs).
4. **Build and download** this project to the CX8190, same as any other
   change here — physically verify before trusting it, same standing rule
   as every other PLC change in this project.

## Django side

- **`find_device/plc/modbus_client.py`** — new, mirrors `ads_client.py`'s
  shape (lock, background reconnect thread, health dict). Point-level API
  only (`read_dali_level`, `write_relay`, etc.) — no raw register calls
  outside this file.
- **`find_device/plc/registry.py`** — holds an optional `ModbusClient`,
  instantiated only when `PLC_MODBUS_ENABLED=true`, same IP as ADS
  (different port, 502). New methods `read_dali_actual_pct`,
  `write_dali_brightness`, `read_relay_actual`, `write_relay_state` try ADS
  first and fall back to Modbus (channels 1-16 / 1-4 only) if ADS raises.
  `read_full_state()`'s DALI/relay batch reads get the same gap-filling.
- **`find_device/views.py`** — `set_dali_brightness`/`set_relay` (the
  single-channel endpoints) now call the registry fallback wrappers instead
  of writing to the ADS device object directly. `set_dali_brightness_all`,
  `set_room_brightness`, and everything curtain/switch/sensor-related are
  unchanged — ADS-only, no fallback.

**Curtains have no Django integration at all yet**, via ADS or Modbus — the
existing `CurtainMotor` class models a different, never-wired hardware
convention (`gvlIO`/`gvlMotor`, INT-based stop/up/down) left over from before
real curtain hardware existed. `POU_Modbus` correctly exposes the *new*
`gvlCurtain` button model over Modbus, ready for whenever a matching Django
device class gets built — that's a separate piece of work, not done here.

**Also not done:** write-fallback for the bulk endpoints (`..._all`,
`..._room`) — scoped out to keep this change reviewable. Only the
single-channel write path has the ADS→Modbus fallback right now.
