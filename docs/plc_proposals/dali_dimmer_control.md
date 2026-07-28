# Proposed TwinCAT change: app control of the 30 DALI dimmer channels

**Status: reverted. Do not redeploy this as-is.** This was built and
downloaded to the real CX8190 once. Wiring `bOn` into the 28
previously-unconnected switch-driven instances (see "What this adds" below)
fought with the existing switch/motion-sensor logic once live — the FB
apparently treats a connected `bOn` as a continuous command rather than an
inert pin, so a permanently-FALSE array value suppressed normal switch
behavior. Result: most switches stopped operating lights and sensor-driven
lights stopped working, building-wide, until caught and fixed on-site.

All four PLC source files touched (`POU.TcPOU`, `gvlDALI.TcGVL`,
`WallLight_POU.TcPOU`, `POU_GUEST_Bathroom.TcPOU`) have been reverted to
their pre-change state. None of the `aPyDali*` variables described below
currently exist on the real PLC — `find_device/plc/devices.py`'s
`DaliChannel` class will hit `ADSError: symbol not found` for every
read/write until this is redesigned. The `bSetLevel`/`nLevel`/`nLevel`
retargeting portion of this proposal (non-`bOn` pins) was never
independently confirmed safe on its own — treat the whole proposal as
unverified, not just the `bOn` piece, until it can be re-applied and
physically tested pin-by-pin rather than all 30 channels at once.

**Gotcha hit and fixed during the first deploy attempt (documented for next
time):** `gvlDALI` is declared `{attribute 'qualified_only'}`, so every
reference to its members must be written as `gvlDALI.aPyDaliLevel[N]`,
never the bare `aPyDaliLevel[N]` — unlike the scalars this replaced
(`bSetLevel`/`nLevel`/`nActualLevel`), which were local to `PROGRAM POU`
itself and correctly bare.

## Why

`POU.TcPOU` (the main DALI program, a CFC/graphical diagram, not ST) declares
30 `fbDALI102Dimmer*Switch` function block instances — one per DALI address —
plus 4 group "all off" blocks. Confirmed by parsing the actual CFC wiring
(pin-to-pin connection graph, not a guess):

- Every instance's `bSwitch` input is wired to its own real hardware
  `gvlDALI.bSwitchOnN`, and its `nAddress`/`eAddressType` are hardcoded
  constants — the physical wall-switch-driven half already works, same as
  the wall relays.
- **`bSetLevel` and `nLevel` are wired identically into all 30 instances at
  once.** Writing these today would broadcast to every DALI light
  simultaneously — not control one chosen light.
- **`nReferenceDeviceAddress`** — the input that would logically let you
  target one specific device — **is wired to nothing on any of the 30
  instances.** The addressing scheme was started but never finished.
- **`nActualLevel`** (brightness readback) is a single shared variable that
  all 30 instances overwrite every scan cycle — not usable to read any one
  light's real brightness.
- `bOn`, `bToggle`, `bGoToScene`, `nScene` are unconnected on 28 of the 30
  instances (dimmers 30/31 are motion-only, same pattern as the Guest
  Bathroom light — no switch, sensor drives bOn/bOff directly).

Net effect: none of the 30 DALI channels has a usable per-light ADS control
path today, for the same fundamental reason as the wall relays — nothing
in the PLC program reads a Python-writable "command this one light" input.

**Side finding, unrelated to control but worth knowing:** several DALI
short addresses are assigned to more than one instance (e.g. address 15
appears on 3 different `fbDALI102DimmerNSwitch` calls; address 4 on 3;
address 5 on 3; address 11 on 3). That's a pre-existing configuration
inconsistency in the PLC program itself, not something introduced by this
proposal or by the app — flagging it since it may explain unexpected
light-grouping behavior independent of anything here.

## What this adds

A per-channel command/readback array in `gvlDALI`, wired individually into
each of the 30 `fbDALI102DimmerNSwitch` calls' own `bSetLevel`, `nLevel`,
`bOn`, `bOff`, and `nActualLevel` pins — replacing the current shared-scalar
broadcast wiring with real, independently addressable channels.

```
// gvlDALI additions — one set per DALI dimmer instance (1..28, 30, 31;
// 29 doesn't exist, skip it)
aPyDaliSetLevel : ARRAY[1..31] OF BOOL;   // rising edge commits aPyDaliLevel[N]
aPyDaliLevel    : ARRAY[1..31] OF BYTE;   // desired level, 0-254
aPyDaliOn       : ARRAY[1..31] OF BOOL;   // rising edge = on
aPyDaliOff      : ARRAY[1..31] OF BOOL;   // rising edge = off
aPyDaliActual   : ARRAY[1..31] OF BYTE;   // real per-channel readback
```

For each instance N, in the CFC diagram:
- Rewire `bSetLevel` input from the shared `bSetLevel` to `aPyDaliSetLevel[N]`
- Rewire `nLevel` input from the shared `nLevel` to `aPyDaliLevel[N]`
- Wire `bOn` to `aPyDaliOn[N]`, `bOff`/equivalent to `aPyDaliOff[N]` (only
  applicable to the 28 switch-driven instances — leave 30/31 sensor-only)
- Wire `nActualLevel` output to `aPyDaliActual[N]` instead of the shared
  `nActualLevel`

This is 30 repetitions of the same small rewiring, not new logic — every
instance already has a working FB call, it's just plumbed to the wrong
(shared) variables. No existing wall-switch or motion-sensor behavior
changes; only the currently-dead `bSetLevel`/`nLevel`/`bOn`/`nReferenceDeviceAddress`
pins get real per-channel wiring.

Recommend doing this **after** the smaller wall-relay proposal
(`README.md`) — same pattern, much smaller blast radius (4 channels vs 30),
good way to confirm the approach works before touching all 30 dimmers.

## Django-side status

`DaliChannel` in `devices.py` was updated to target
`aPyDaliLevel[N]`/`aPyDaliSetLevel[N]`/`aPyDaliOn[N]`/`aPyDaliActual[N]`
while this proposal was briefly live, and has been left pointing at those
names (documented in its docstring as currently non-functional) rather than
reverted to the equally-nonexistent original names — either way nothing
real backs these symbols right now. Once a redesigned, physically-verified
wiring exists, repoint the same three `_var_*` properties again.

The 16 "Light 1-16" `ApartmentDevice` rows currently in the database are
generic placeholder data (channel numbers 1-16, sequential) that don't
correspond to the real DALI short addresses in use (which are non-
sequential and, per the duplicate-address finding above, not even
uniquely assigned per instance). These will need to be re-mapped to real
instance numbers (1-28, 30, 31) once the wiring above exists and someone
can confirm in person which physical light is which address.
