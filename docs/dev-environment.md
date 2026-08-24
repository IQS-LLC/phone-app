# Local Development Environment

Everything in this doc runs entirely on one machine, with no real PLC
hardware required — the backend's `PLC_MOCK` mode and the `seed_demo`
management command exist specifically to make this possible. All paths below
are relative to wherever you cloned the repo (`<repo>`); nothing here should
ever be a machine-specific absolute path — if you find one, it's a bug in
this doc (see `docs/AUDIT_FINDINGS.md` for why that matters).

## Fastest path: mock PLC, no hardware, no emulator

```bash
cd <repo>

# 1. Apply migrations (safe to re-run — no-ops if already applied)
python manage.py migrate

# 2. Seed demo users across every role/apartment (idempotent — safe to re-run)
python manage.py seed_demo --ip 127.0.0.1

# 3. Start Django in mock-PLC mode
#    PowerShell:
$env:PLC_MOCK = "True"
python manage.py runserver 127.0.0.1:8000
#    bash/zsh:
PLC_MOCK=True python manage.py runserver 127.0.0.1:8000
```

`seed_demo` prints every account it creates as it runs. As of this writing
that's one account per role (`admin_diana`, `owner_oliver`, `family_fiona`,
`guest_gary`, `cleaner_carlos`, `tech_tina`, `installer_ivan`,
`owner_olivia8`), all sharing the password `Demo12345!` — check the command's
own output for the current, authoritative list rather than trusting this doc
if the two ever disagree.

## Running the Flutter app against it

The login screen has no visible server-URL field by design (see
`flutter_application_plc/lib/config/runtime_config.dart`'s doc comment —
that's a deliberate anti-phishing decision, not an oversight) — the address
is baked in at launch via `--dart-define=LUGH_SERVER_URL`.

```bash
cd <repo>/flutter_application_plc

# Windows desktop app, talking to the Django you just started on this same PC
flutter run -d windows --dart-define=LUGH_SERVER_URL=http://127.0.0.1:8000

# Chrome, same idea
flutter run -d chrome --dart-define=LUGH_SERVER_URL=http://127.0.0.1:8000

# Android emulator (10.0.2.2 is the emulator's own alias for the host machine)
flutter run -d emulator-5554 --dart-define=LUGH_SERVER_URL=http://10.0.2.2:8000

# A real phone on the same LAN — replace with this machine's actual LAN IP
flutter run -d <device-id> --dart-define=LUGH_SERVER_URL=http://<this-machine-LAN-IP>:8000
```

Log in with any `seed_demo` account, e.g. `family_fiona` / `Demo12345!`.

`LUGH_SERVER_URL` also accepts a comma-separated list (the multi-endpoint
Cloudflare failover pool used in production) — a single URL is just the
one-element case, so nothing above changes for local dev.

## Connecting to a real Beckhoff CX instead of mock

Three things have to be true before Django can talk to real hardware — this
is a network/TwinCAT step first, then a database row:

1. **Network reachability.** The Django host must reach the CX's IP on TCP
   48898 (ADS router) and its runtime port (851 by default). Same subnet:
   nothing to configure. Different subnets: a router must exist between
   them — ADS is a normal routed TCP connection once a route exists (next
   step), it doesn't do cross-subnet auto-discovery.
2. **An ADS route between the two machines.** TwinCAT rejects connections
   from an unknown AMS Net ID by default. From the Django machine, register a
   route on the CX pointing back here (already wired into
   `find_device/plc/ads_client.py`):

   ```bash
   python manage.py shell -c "
   from find_device.plc.ads_client import ADSClient
   c = ADSClient(netid='<this-machine-net-id>', ip='<CX-IP>')
   c.add_route(sender_net_id='<this-machine-net-id>')
   "
   ```

   AMS Net ID is normally the machine's IP + `.1.1` (e.g.
   `192.168.0.158.1.1`) unless TwinCAT's been configured otherwise — check in
   TwinCAT's AMS Router config on the CX if unsure.
3. **Register the `PLCDevice` row and turn mock mode off.**

   ```bash
   python manage.py shell -c "
   from find_device.models import Apartment, PLCDevice
   apt = Apartment.objects.get(name='<apartment name>')
   PLCDevice.objects.update_or_create(
       apartment=apt,
       defaults=dict(
           owner_id=1,  # any existing user id
           name='Real CX',
           ip_address='<CX-IP>',
           ams_net_id='<CX-IP>.1.1',
           ads_port=851,
           is_active=True, is_default=True,
       ),
   )
   "
   $env:PLC_MOCK = "False"
   python manage.py runserver 0.0.0.0:8000
   ```

**Important — this is not automatic fallback.** `PLC_MOCK` is an explicit,
opt-in environment variable. If the real CX is unreachable while `PLC_MOCK`
is `False`, `DeviceRegistry` does **not** silently fall back to mock data —
it reports the apartment as unreachable (see
`find_device/plc/registry.py`'s "No mock fallback" comment). An earlier
version of this doc claimed otherwise; that was wrong even at the time it was
written and has been corrected here. If you want mock behavior, set
`PLC_MOCK=True` yourself.

## Known real limitation (not a bug, a hardware-wiring gap)

As of this writing, DALI dimmer channel brightness control only reaches real
hardware for the 4 wall relays — the DALI dimmer channels themselves aren't
wired into the live PLC control logic yet (that's a TwinCAT-side task, not a
Django/Flutter one). Against a real PLC: relay on/off works; DALI brightness
sliders write the GVL correctly but won't move an actual light until that
TwinCAT wiring is done. See `docs/plc-integration.md`'s hardware support
matrix for the current, authoritative state of what's real vs. mock-only.
