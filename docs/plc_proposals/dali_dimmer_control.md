# TwinCAT change: app control of the 30 DALI dimmer channels + 4 wall relays

**Status: redesigned and re-deployed to source, not yet built/downloaded to
the real CX8190.** The first attempt wired `bOn` into 28
previously-unconnected switch-driven instances and that fought with the
existing switch/motion-sensor logic once live — the FB apparently treats a
connected `bOn` as a continuous command rather than an inert pin, so a
permanently-FALSE array value suppressed normal switch behavior. Result:
most switches stopped operating lights and sensor-driven lights stopped
working, building-wide, until caught and fixed on-site. All four PLC
source files touched by that attempt were fully reverted.

**This redesign, isolated in two brand-new files:**
- `GVLs/gvlController.TcGVL` — every variable the app reads/writes, in one
  place, separate from `gvlDALI`/`gvlDALI_State`.
- `POUs/POU_Controller.TcPOU` — the logic connecting those variables to the
  real hardware. Called last from `MAIN` (after `POU_GUEST_Bathroom`).
  Doesn't edit `WallLight_POU.TcPOU` or `POU_GUEST_Bathroom.TcPOU` at all.

**The one deliberate change from the first attempt: `bOn` is not wired,
anywhere, on any of the 30 instances.** On/off is expressed purely through
level (0 = off, >0 = on) via the same `bSetLevel`/`nLevel` pins already
used for dimming — the only pins retargeted are `bSetLevel`, `nLevel`, and
`nActualLevel`. `bOn`/`bOff` are untouched on every instance, including
30/31 where they're wired to a motion sensor, verified byte-identical
against the pre-change file (same connection graph, same pin IDs).

Wall relay control (Lights 1/3/4) goes through the same isolated POU,
setting `gvlDALI_State.bLightStateN` on a rising edge — the same internal
state `WallLight_POU` already mirrors into `bRelayN` every scan, so it
behaves exactly like a physical switch press without editing that POU.
Light 2 / Guest Bathroom (relay 1) is driven by a motion sensor via
`POU_GUEST_Bathroom`, not by that shared state, so `POU_Controller` handles
it with its own override-that-clears-on-sensor-transition logic instead,
running after `POU_GUEST_Bathroom` so it has the final say each scan.

**Still true, and worth being honest about:** the `bSetLevel`/`nLevel`
retargeting itself was never independently physically verified in
isolation — only the `bOn` wiring was conclusively identified as the cause
of the outage. This redesign removes the one proven-dangerous piece, but
"all 30 channels in one build/download" was a deliberate choice to move
faster rather than pilot one channel first — physically test all of it
(switches, motion sensors, and the new app controls) before trusting it.

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

`DaliChannel` and `WallRelay` in `devices.py` point at the new
`gvlController.*` names described above. `DaliChannel.turn_on()`/
`turn_off()` are now level-based (`set_brightness(100)`/`set_brightness(0)`)
instead of writing a `bOn` pin, since none is wired. All of this will hit
`ADSError: symbol not found` until the TwinCAT side is actually built and
downloaded to the real CX8190.

The 16 "Light 1-16" `ApartmentDevice` rows currently in the database are
generic placeholder data (channel numbers 1-16, sequential) that don't
correspond to the real DALI short addresses in use (which are non-
sequential and, per the duplicate-address finding above, not even
uniquely assigned per instance). These will need to be re-mapped to real
instance numbers (1-28, 30, 31) once the wiring above exists and someone
can confirm in person which physical light is which address.
