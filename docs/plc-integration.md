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

**The gap, and how it's now bridged (2026-08-24):** SuperScan's
classification used to be *display-only* — it populated a read-only
discovery dashboard but never created the `ApartmentDevice` rows
`DeviceRegistry` actually builds live control objects from. Two additions
close that gap for the common case:

- **`find_device.models.DeviceAddressScheme`** — a database row that
  carries a GVL prefix + `.format()`-style read/write/commit templates +
  PLC type + protocol, instead of a hardcoded Python class. `ApartmentDevice`
  has an optional `address_scheme` FK; when set, `DeviceRegistry._start()`
  builds that row as a `devices.TemplatedDevice` instead of dispatching on
  `device_type` to a hardcoded class. Every device created before this field
  existed (and every one created the normal way since) has `address_scheme
  = null` and is completely unaffected — this is purely additive.
- **`POST /superscan/<apartment_id>/capabilities/<cap_id>/promote/`**
  (staff-only, `superscan_views.promote_capability`) — creates that
  `ApartmentDevice` + `DeviceAddressScheme` directly from a
  SuperScan-discovered symbol's `raw_var_name`/`data_type`, so a discovered
  symbol can become a controllable device without hand-editing the database.

**Still a real limit, by design**: the promote endpoint and
`TemplatedDevice` only handle the simple case — one fixed scalar symbol (or
an indexed one via `index_offset`), read/write with an optional
commit-pulse. A device whose *protocol shape* differs (not just its
address) — e.g. `CurtainMotor`'s momentary-button semantics — still needs a
real Python class, the same as every class below. Adding a new GVL layout
that fits the simple shape is now a database row; anything with genuinely
different protocol behavior is still new Python, and that's an intentional
boundary, not an oversight — see the class docstrings for the more nuanced
patterns (write-then-pulse-commit, batch reads, momentary buttons) a bare
template can't express.

### Hardware Support Matrix (as of the 2026-08-24 audit)

| Device class | GVL | Real hardware today? | Notes |
|---|---|---|---|
| `DaliChannel` | `gvlController` | Partial | Relay-driven channels work; DALI dimmer channels write the GVL correctly but aren't wired into the live PLC logic yet (TwinCAT-side task) — see `docs/plc_proposals/README.md` for the proposed fix, why it's not deployed (a related change broke building-wide switch lighting once live and both were reverted together), and the plan to re-apply and test in isolation |
| `WallRelay` | `gvlDALI`/`gvlController` | Yes | |
| `SwitchInput` | `gvlDALI` | Yes, for indices with real wiring — index 3 has a known symbol mismatch (pre-existing, unfixed) | |
| `MotionSensor` | `gvlDALI` | Indices 1-4 only | Indices 5-8 are mock-only |
| `CurtainMotor` | `gvlCurtain` | Yes | Momentary-button model, not position-feedback |
| `ApplianceRelay`, `MagneticSensor`, `SecurityController` | `gvlIO` | **No** | `gvlIO` doesn't exist in either apartment's TwinCAT project; these are mock-only until matching hardware/PLC logic exists |
| Modbus fallback (`modbus_client.py`) | separate register/coil map | Only DALI 1-16, relay 1-4 | Fully parallel implementation, no shared code with the ADS classes above; curtains/switches/sensors/appliances have no Modbus path |

### Extending to a new GVL layout or device generation

Two paths, depending on what's actually different:

1. **A pure addressing/naming difference** (a different GVL prefix, a
   different array-index convention, a different PLC generation that
   exposes the same read/write/commit shape under different names) — create
   a `DeviceAddressScheme` row (Django admin, or via the promote endpoint if
   the symbol was SuperScan-discovered first) and point an `ApartmentDevice`
   at it via `address_scheme`. No Python change, no redeploy. See
   `find_device/models.py`'s `DeviceAddressScheme` docstring for the exact
   template placeholders (`{gvl}`, `{index}`, `{gvl_name}`) and
   `find_device/plc/devices.py`'s `TemplatedDevice` for how it's interpreted.
2. **A genuinely different protocol shape** — e.g. a device where reading
   back the confirmed state needs a different variable than a simple
   readback, or command semantics that aren't "write a value, optionally
   pulse a commit bit" (like `CurtainMotor`'s momentary-button model, or a
   hypothetical position-feedback curtain motor). This still needs a new
   Python class in `devices.py` following the pattern of the classes above,
   wired into `DeviceRegistry._start()`'s dispatch — a bare address template
   can't express arbitrary protocol logic, and that's intentional: forcing
   real logic into a template string would make it harder to read and test,
   not easier.

When unsure which case you're in: if you can describe the fix as "same kind
of read/write, different variable name," it's case 1. If you find yourself
wanting an `if` statement inside the template, it's case 2.

### Modbus TCP fallback

Optional, off by default (`PLC_MODBUS_ENABLED=false`). Requires a TF6250
license installed on the CX. Gives DALI channels 1-16 and relays 1-4 a
second path (port 502) that survives AMS-route/Secure-ADS failures that ADS
alone doesn't. See `docs/plc_proposals/modbus_bridge.md` for the register
map and rollout notes before enabling it.
