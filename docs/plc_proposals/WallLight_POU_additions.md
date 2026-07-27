# WallLight_POU.TcPOU — proposed additions

Source reviewed: `Apartmant16/TwinCAT DALI Sensor Project/DALI_PLC/POUs/WallLight_POU.TcPOU`
(read-only — this repo's copy was not modified).

## 1. Declaration block

Current:
```
PROGRAM WallLight_POU
VAR
    rTrig_Button0  : R_TRIG;
    rTrig_Button1  : R_TRIG;
    rTrig_Button2  : R_TRIG;
    rTrig_Button3  : R_TRIG;
    tOff0          : TON;
    tOff1          : TON;
    tOff2          : TON;
    tOff3          : TON;
END_VAR
```

Add 4 lines (one new edge-trigger per light):
```
    rTrig_PySet0   : R_TRIG;
    rTrig_PySet1   : R_TRIG;
    rTrig_PySet2   : R_TRIG;
    rTrig_PySet3   : R_TRIG;
```

## 2. ST implementation — one 4-line block per light

For each light `N` (0-3), insert the new block **right after** the existing
physical-button `IF` block and **before** the motion-sensor `IF` block —
same position a button press occupies today, so app commands and physical
switch presses behave identically (including racing the same way with an
active motion sensor, which is already how a button press behaves).

### Light 1 — insert after line 23 (`END_IF` closing the button block), before line 24
```
IF rTrig_Button0.Q THEN
    gvlDALI_State.bLightState0 := NOT gvlDALI_State.bLightState0;
    gvlDALI_State.bSensorOn0   := FALSE;
END_IF
                                                    <<< INSERT HERE
rTrig_PySet0(CLK := gvlDALI.bPyRelaySet0);
IF rTrig_PySet0.Q THEN
    gvlDALI_State.bLightState0 := gvlDALI.bPyRelayCmd0;
    gvlDALI_State.bSensorOn0   := FALSE;
END_IF
                                                    <<< END INSERT
IF gvlDALI.bSensor0 AND NOT gvlDALI_State.bLightState0 THEN
```

### Light 2 — same pattern, after the Light 2 button block
```
rTrig_PySet1(CLK := gvlDALI.bPyRelaySet1);
IF rTrig_PySet1.Q THEN
    gvlDALI_State.bLightState1 := gvlDALI.bPyRelayCmd1;
    gvlDALI_State.bSensorOn1   := FALSE;
END_IF
```

### Light 3
```
rTrig_PySet2(CLK := gvlDALI.bPyRelaySet2);
IF rTrig_PySet2.Q THEN
    gvlDALI_State.bLightState2 := gvlDALI.bPyRelayCmd2;
    gvlDALI_State.bSensorOn2   := FALSE;
END_IF
```

### Light 4
```
rTrig_PySet3(CLK := gvlDALI.bPyRelaySet3);
IF rTrig_PySet3.Q THEN
    gvlDALI_State.bLightState3 := gvlDALI.bPyRelayCmd3;
    gvlDALI_State.bSensorOn3   := FALSE;
END_IF
```

## Why this shape specifically

- **Additive only** — no existing line is changed or removed. The physical
  switch (`bSwitchOn30-33`) and motion sensor (`bSensor0-3`) paths are
  untouched.
- **Edge-triggered, not level-driven** — `bPyRelaySetN` must go
  TRUE→FALSE (a pulse) to take effect, exactly like `DaliChannel.set_brightness()`
  already does for `aPySetLevel` in the Django code. This means a stale
  `TRUE` left on the wire (e.g. app crash mid-write) can't permanently pin
  the relay — it just does nothing until the next real pulse.
- **`gvlDALI.bRelayN := gvlDALI_State.bLightStateN`** at the bottom of each
  light's block (unchanged, already exists) means the relay output updates
  automatically from whichever path last touched `bLightStateN` — button,
  sensor, or now the app. No new relay-output logic needed.
