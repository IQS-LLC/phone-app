Start everything (local dev / demo, mock PLC)

cd "c:\Users\Automation\Desktop\phoneapp+apartment-16\phone-app"

# 1. Apply migrations (safe to re-run, no-ops if already applied)
python manage.py migrate

# 2. Seed demo users across every role/apartment (idempotent — safe to re-run)
python manage.py seed_demo --ip 10.0.2.2

# 3. Start Django, bound so both the emulator and LAN devices can reach it
$env:PLC_MOCK = "True"
python manage.py runserver 0.0.0.0:8000
Open a second terminal for Flutter (the --dart-define is required now — the login screen no longer has a server field, so the address must be baked in at launch):


cd "c:\Users\Automation\Desktop\phoneapp+apartment-16\phone-app\flutter_application_plc"

# Android emulator (10.0.2.2 = emulator's alias for this PC)
flutter run -d emulator-5554 --dart-define=LUGH_SERVER_URL=http://10.0.2.2:8000

# Real phone on the same WiFi instead — use this PC's LAN IP
flutter run -d <device-id> --dart-define=LUGH_SERVER_URL=http://192.168.0.158:8000
Demo logins (seed_demo prints these too, password is the same for all): admin_diana, owner_oliver, family_fiona, guest_gary, cleaner_carlos, tech_tina, installer_ivan, owner_olivia8 — password Demo12345!.

Or, the one-command version using the script I fixed earlier this session (does steps 1-3 for you, prints the credentials, then launches Flutter):


.\start_project.ps1 -Mode local
Connecting to a real Beckhoff CX
This is a network/TwinCAT step first, then a database row — there's no UI for it yet (that's the "PLC Registration workflow" from the infra request, not built). Three things have to be true before Django can talk to a real PLC:

1. Network reachability. The Django server's machine must be able to reach the CX's IP on TCP port 48898 (ADS router) and the runtime port (851 by default). Same subnet: nothing to configure. Different subnets: a router must exist between them — ADS is a normal routed TCP connection once an ADS route exists (see next step), it just doesn't do cross-subnet auto-discovery (covered in the network-discovery design from earlier).

2. An ADS route between the two machines. TwinCAT requires an explicit route — it won't accept connections from an unknown AMS Net ID by default. On the CX, via TwinCAT's "Add Route" (or pyads.add_route_to_target, already wired into ads_client.py):


# From the Django machine, register a route ON the CX pointing back here.
# Replace with this machine's real AMS Net ID and the CX's IP.
python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
c = ADSClient(netid='<this-machine-net-id>', ip='<CX-IP>')
c.add_route(sender_net_id='<this-machine-net-id>')
"
Net ID is usually the machine's IP + .1.1 (e.g. 192.168.0.158.1.1) unless TwinCAT's been configured otherwise — check in TwinCAT's AMS Router config on the CX if unsure.

3. Register the PLCDevice + flip off mock mode.


cd "c:\Users\Automation\Desktop\phoneapp+apartment-16\phone-app"
python manage.py shell -c "
from find_device.models import Apartment, PLCDevice
apt = Apartment.objects.get(name='Apartment 16')
PLCDevice.objects.update_or_create(
    apartment=apt,
    defaults=dict(
        owner_id=1,  # any existing user id — installer/owner
        name='Real CX',
        ip_address='192.168.0.161',       # <-- the CX's real IP
        ams_net_id='192.168.0.161.1.1',   # <-- the CX's real AMS Net ID
        ads_port=851,
        is_active=True, is_default=True,
    ),
)
"

# Then start Django WITHOUT mock mode:
$env:PLC_MOCK = "False"
python manage.py runserver 0.0.0.0:8000
If the CX is unreachable when Django starts, DeviceRegistry automatically falls back to mock for that apartment and logs a warning (registry.py's _start() — built-in resilience, not a crash). Watch the console for "PLC unreachable — falling back to mock" to confirm whether the real connection actually took.

One real caveat from earlier this session, worth repeating: brightness control only works for the 4 wall relays right now — the 28 DALI dimmer channels aren't wired into the live POU.TcPOU CFC yet (needs you in TwinCAT XAE). Against a real PLC, relay on/off will work; DALI brightness sliders will write the GVL but won't move actual lights until that wiring is done.

okay that is great but one more for local and dev t4st purposes n local drive and server
The user wants a local-only setup guide for testing both the Django backend and Flutter app on a single machine without needing external hardware or emulators.

Since Windows desktop is available as a Flutter target, I can provide a straightforward approach: run Django on localhost and launch the Flutter app as a Windows desktop build pointing to that same local server, avoiding all the networking complexity of emulators or LAN setups. I'll offer both the Windows desktop and Chrome web options since both are viable locally, then verify the dart-define approach works with those targets.

Got it — fully local on this one machine, no emulator/phone needed. Simplest path: Django on 127.0.0.1 + Flutter as a Windows desktop app (or Chrome), both on localhost.


# Terminal 1 — backend
cd "c:\Users\Automation\Desktop\phoneapp+apartment-16\phone-app"
python manage.py migrate
python manage.py seed_demo --ip 127.0.0.1
$env:PLC_MOCK = "True"
python manage.py runserver 127.0.0.1:8000

# Terminal 2 — frontend (Windows desktop app)
cd "c:\Users\Automation\Desktop\phoneapp+apartment-16\phone-app\flutter_application_plc"
flutter run -d windows --dart-define=LUGH_SERVER_URL=http://127.0.0.1:8000
Or instead of Windows desktop, run it in Chrome (also already confirmed working on this machine):


flutter run -d chrome --dart-define=LUGH_SERVER_URL=http://127.0.0.1:8000
Log in with any seed_demo account (e.g. family_fiona / Demo12345!). No emulator, no ADB, no firewall rules needed — pure loopback, both processes on this PC.

One thing to flag: I haven't actually launched the Windows-desktop build in this session (only Android emulator) — if it throws a build error, run flutter doctor first and tell me what it says, since the Windows toolchain setup could have drifted since I last checked it.