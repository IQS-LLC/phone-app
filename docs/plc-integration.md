# PLC / GVL Integration

## Prerequisites

- Beckhoff CX powered on, connected to the LAN
- TwinCAT 3 runtime installed and set to **RUN** state
- PLC program deployed and executing
- The Django host and the CX on the same subnet (or a route between them)

**To verify the PLC's current IP:** on the CX display, or in TwinCAT System
Manager → Target System → Properties.

## Required network ports

```bash
docker exec lugh_django nc -zv <PLC_IP> 48898   # ADS router
docker exec lugh_django nc -zv <PLC_IP> 851     # TwinCAT 3 runtime
```

Both must succeed. If either fails: check the CX's firewall (allow TCP 48898
and 851 inbound), check any network firewall/ACL between the Django host and
the CX, verify they're on the same switch (no inter-VLAN routing blocking
them).

## Add an ADS route on the Beckhoff CX

The CX must have a static route telling it how to reach the Django host, or
ADS communication is refused.

**Method A — TwinCAT System Manager:**
1. Connect to the CX at its IP from an engineering PC on the same LAN.
2. Routes tab → Add Route.
3. Route Name: anything memorable. AMS Net ID: the Django host's, `IP.1.1`.
   Address: the Django host's IP. Transport: TCP/IP.

**Method B — programmatically** (already wired into
`find_device/plc/ads_client.py`):

```bash
docker exec lugh_django python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
client = ADSClient('<PLC_AMS_NET_ID>', '<PLC_IP>')
result = client.add_route('<DJANGO_HOST_AMS_NET_ID>', 'Lugh-Backend')
print('Route added:', result)
"
```

`ads_client.py` also auto-repairs this route if TwinCAT resets it, **but
only if `PLC_ROUTE_USERNAME`/`PLC_ROUTE_PASSWORD` are set in `.env`** —
without both, auto-repair silently no-ops. This has historically been the
single most common recurring PLC connectivity failure in this project; if a
route keeps disappearing, check these two env vars first.

## Verify the ADS connection

```bash
docker exec lugh_django python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
client = ADSClient('<PLC_AMS_NET_ID>', '<PLC_IP>')
ok = client.connect()
print('Connected:', ok)
if ok:
    print('Device:', client.get_device_info())
    print('ADS state:', client.read_ads_state())
    client.disconnect()
"
```

Expected when the PLC is running: `ADS state: {'ads_state': 5, ...}`. State
5 = RUN. Anything else means the PLC program isn't executing.

## AMS Net ID rule

Always `<IP>.1.1` — the TwinCAT default for the local AMS Net ID of any
target, not configurable in this system. If either the CX's or the Django
host's IP changes, both AMS Net IDs change with it — update `.env`
(`PLC_NETID`), the ADS route on the CX, and the `PLCDevice` record in the
app (Settings → Controllers → edit).

---

## GVL layout and device abstraction — the real, current state

See `docs/AUDIT_FINDINGS.md` §1 for the full audit this section summarizes.
**There is no single fixed GVL naming convention** — two different parts of
this codebase currently have two different vocabularies:

1. **The live control path** (`find_device/plc/devices.py`) hardcodes a GVL
   prefix and addressing formula per Python class. As of this writing, for
   Apartment 16's actual TwinCAT project:
   - `gvlController.aDaliLevel[n]` / `aDaliSetLevel[n]` / `aDaliActual[n]` —
     DALI brightness (`DaliChannel`, channels 1-31, some gaps).
   - `gvlDALI.bRelay{n}` / `gvlController.bRelayCmd{n}` / `bRelaySet{n}` —
     wall relays (`WallRelay`, channels 1-16).
   - `gvlDALI.bSwitchOn{n}` — physical switch inputs (`SwitchInput`, 1-48).
   - `gvlDALI.bSensor{n}` — motion sensors (`MotionSensor`, 1-8, only 1-4
     have real hardware behind them today).
   - `gvlCurtain` via `POU_Curtain`'s momentary-button model — curtain
     motors (`CurtainMotor`, 2 physical curtains).
   - `gvlIO.*` — appliance relays, door/window sensors, alarm/lockdown
     (`ApplianceRelay`, `MagneticSensor`, `SecurityController`). **This GVL
     does not exist in either apartment's real TwinCAT project** — these
     classes only ever worked in `PLC_MOCK` mode; see the Hardware Support
     Matrix below.
2. **The SuperScan discovery classifier**
   (`find_device/discovery/classifier.py`) has its own, more generic
   category vocabulary (`gvldali`, `gvlhvac`, `gvlalarms`, `gvlrelays`,
   `gvlswitch`, `gvlinput`, `gvloutput`, `gvlsensor`, `gvlmotor`, `gvlpump`,
   `gvlvalve`, `gvlenergy`) designed to classify *whatever* symbols a scan
   finds, on *any* TwinCAT project — it doesn't assume the specific
   `gvlController`/`gvlCurtain` names above. This is genuinely dynamic:
   `find_device/discovery/scanner.py` enumerates every ADS symbol live, and
   `classifier.py`'s `classify()` assigns a widget type from a GVL-prefix
   table + regex name-token patterns + ADS type, with a safe `unknown`
   fallback for anything it doesn't recognize.

**The gap**: SuperScan's classification is currently *display-only* — it
populates a read-only discovery dashboard but never creates the
`ApartmentDevice` rows that `DeviceRegistry` actually builds live control
objects from. An installer still manually creates `ApartmentDevice` rows
(setting `channel_or_index` and `gvl_name`), and those rows are only
understood by whichever hardcoded `devices.py` class matches their
`device_type` — adding a genuinely new GVL layout (a different PLC
generation, a different integrator's naming convention) means writing a new
Python class today, not adding a config row.

### Hardware Support Matrix (as of the 2026-08-24 audit)

| Device class | GVL | Real hardware today? | Notes |
|---|---|---|---|
| `DaliChannel` | `gvlController` | Partial | Relay-driven channels work; DALI dimmer channels write the GVL correctly but aren't wired into the live PLC logic yet (TwinCAT-side task) |
| `WallRelay` | `gvlDALI`/`gvlController` | Yes | |
| `SwitchInput` | `gvlDALI` | Yes, for indices with real wiring — index 3 has a known symbol mismatch (pre-existing, unfixed) | |
| `MotionSensor` | `gvlDALI` | Indices 1-4 only | Indices 5-8 are mock-only |
| `CurtainMotor` | `gvlCurtain` | Yes | Momentary-button model, not position-feedback |
| `ApplianceRelay`, `MagneticSensor`, `SecurityController` | `gvlIO` | **No** | `gvlIO` doesn't exist in either apartment's TwinCAT project; these are mock-only until matching hardware/PLC logic exists |
| Modbus fallback (`modbus_client.py`) | separate register/coil map | Only DALI 1-16, relay 1-4 | Fully parallel implementation, no shared code with the ADS classes above; curtains/switches/sensors/appliances have no Modbus path |

### Extending to a new GVL layout or device generation

Today, this genuinely requires writing a new Python class in
`find_device/plc/devices.py` following the existing pattern (see any of the
classes above), then wiring it into `find_device/plc/registry.py`'s
`DeviceRegistry._start()` dispatch. There is an in-progress design (see
`docs/AUDIT_FINDINGS.md`'s referenced plan) to add a `DeviceAddressScheme`
model that lets `ApartmentDevice` carry its own GVL prefix and addressing
template from the database instead — check whether that has landed
(`find_device/models.py`, search for `DeviceAddressScheme`) before writing a
new hardcoded class; if it exists, prefer it for anything that's a pure
addressing difference rather than a genuinely different protocol shape.

**Honest limit**: an address-template approach can't cover every possible
future device — some devices differ in *protocol shape*, not just address
(e.g. `CurtainMotor`'s momentary-button model vs. a hypothetical
position-feedback curtain motor needs different read/write semantics
entirely, not just a different symbol name). A protocol-shape change still
needs a new Python class.

### Modbus TCP fallback

Optional, off by default (`PLC_MODBUS_ENABLED=false`). Requires a TF6250
license installed on the CX. Gives DALI channels 1-16 and relays 1-4 a
second path (port 502) that survives AMS-route/Secure-ADS failures that ADS
alone doesn't. See `docs/plc_proposals/modbus_bridge.md` for the register
map and rollout notes before enabling it.
