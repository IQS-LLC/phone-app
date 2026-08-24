# Commissioning a New Apartment

## Prerequisites

- Backend stack healthy (`GET <server>:9080/health/` returns ok)
- ADS connection verified (`docs/plc-integration.md`)
- PLC in RUN state
- A staff (`is_staff=True`) account
- The mobile app installed and able to reach the backend

## Open the Commissioning Wizard

Log in as a staff user → Home screen → amber **Commission** FAB
(bottom-right) → the 9-step wizard opens.

## Step by step

**1. Network Discovery** — scans the configured LAN subnet for Beckhoff ADS
targets. The CX should appear with connection quality Excellent/Good. If
not found: verify `PLC_DISCOVERY_SUBNETS` in `.env` matches the real subnet,
restart Django.

**2. PLC Connectivity** — enter/confirm IP, AMS Net ID, port (851). ADS
state must show RUN; anything else means the PLC program isn't executing.
To update these later: app → Settings → Controllers → edit → Save → Test
Connection (also update `.env` and restart Django/Celery to match).

**3. Apartment Setup** — create the apartment record: name, building,
floor, rooms. To rename later: Settings → the apartment card → Rename, or
Django admin → `/admin/find_device/apartment/`.

**4. Symbol Discovery** — the backend connects to the PLC and dynamically
enumerates every GVL variable it exposes (see `docs/plc-integration.md` for
how this classification actually works — it's genuinely dynamic, not tied
to one fixed naming scheme). Symbol count should be non-zero. To re-run
after a PLC program change: wizard step 4 again, or `POST
/discovery/<device_id>/scan/`.

**5. Floor Plan Upload** — PNG/JPEG, max 20 MB, stored under
`/volume1/docker/lugh/media/`. Re-running this step replaces the image but
preserves existing device placement on the canvas.

**6. Map Editor** — place each discovered symbol onto the floor plan as a
device icon, linked to its symbol name and device type. To reposition
later: Map Editor FAB (staff only) → drag → Publish.

**7. I/O Commissioning (physical test)** — tap **Test** per device; the
backend pulses the real output:

| Device | Test Action | Duration |
|---|---|---|
| DALI light | Flash to 80% (20% if already bright) | 1.5s |
| Wall relay | Pulse ON | 0.8s |
| Curtain motor | Drive UP | 0.8s |
| Sensor | Read current value (no actuation) | Instant |

If a test fails: verify the symbol is mapped to the correct channel, verify
physical wiring on the DALI bus or relay output, check whether the CX
program's output variable is actually linked to the physical I/O module.

**8. Resident Accounts** — create users, assign role (`owner`: full control
+ user/device management; `resident`: control only, read-only settings). To
add later: Settings → User Management → Add User, or Django admin. To
deactivate for a tenant changeover: find the user → **Disable**, never
delete — this preserves audit history.

**9. Handover** — review and record the commissioning summary.

## Adding a new apartment/building later

Log in as staff → Commissioning Wizard → (if it has its own PLC, register it
first via Settings → Controllers → Add) → run all 9 steps. No server restart
or code change required — apartments are database records.
