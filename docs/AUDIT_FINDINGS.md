# Audit Findings — Ownership Handoff Pass (2026-08-24)

This document captures a direct, file-verified audit performed while planning
the "make this maintainable by someone who's never met the original author"
initiative (see `docs/AUDIT_FINDINGS.md`'s sibling docs for the resulting
work). Every claim below was confirmed by reading the cited file/line, not
inferred — treat this as a snapshot in time, not a live guarantee; re-verify
against current code before relying on a specific line number.

## 1. GVL/device abstraction: a real gap, not a missing capability

There are **two separate systems** that both understand PLC symbols, and they
don't talk to each other:

- **`find_device/discovery/scanner.py` + `find_device/discovery/classifier.py`**
  ("SuperScan") is a genuinely flexible, dynamic classification pipeline:
  `scanner.py._scan_real()` enumerates *every* ADS symbol live via `pyads`
  (no hardcoded symbol names), and `classifier.py.classify()` then assigns a
  widget type using a layered approach — GVL-prefix category table
  (`_GVL_CATEGORY`, classifier.py:49-62), then regex name-token patterns
  (alarm/temp/DALI/mode/gauge, classifier.py:69-97), then raw ADS type, with
  an always-safe `WIDGET_UNKNOWN` fallback. This is solid, extensible, and
  should not be rewritten.
- **The problem: it's display-only.** `find_device/discovery/views.py` writes
  results to a `DiscoveryCache` and serves a read-only dashboard. It never
  creates `ApartmentDevice` rows and is never consulted by `DeviceRegistry`.
  An installer still has to manually create `ApartmentDevice` rows, and the
  actual control path — `find_device/plc/devices.py`'s per-type classes
  (`DaliChannel`, `WallRelay`, `NamedRelay`, `SwitchInput`, `CurtainMotor`,
  `ApplianceRelay`, `MagneticSensor`, `MotionSensor`, `SecurityController`) —
  hardcodes its own GVL prefix + addressing formula per class via f-strings
  (e.g. `DaliChannel` → `gvlController.aDaliLevel[{ch}]`, `WallRelay` →
  `gvlDALI.bRelay{ch-1}`/`gvlController.bRelayCmd{ch-1}`). Adding a new GVL
  layout today means writing a new Python class, not a new config row.
- **Channel-count ceilings are global, not per-apartment**: `DaliChannel.
  MAX_CHANNEL=31`, `WallRelay` 1-16, `SwitchInput` 1-48, `CurtainMotor.
  MAX_INDEX=2`, `MagneticSensor` 1-16, `MotionSensor` 1-8 (all in
  `devices.py`); `registry.py`'s `RAW_SWITCH_INDICES=range(1,49)` etc.;
  `modbus_client.py`'s `DALI_CHANNELS=16`/`RELAY_COUNT=4`/`CURTAIN_COILS=4`.
  These apply to every apartment regardless of actual hardware.
- **Partial DB flexibility already exists**: `ApartmentDevice`
  (`models.py:266-338`) has `channel_or_index` (int) and `gvl_name`
  (CharField) — real per-device DB-driven configuration, but `gvl_name` only
  carries a bare identifier; the surrounding GVL prefix and
  Cmd/State/array-index formula is still hardcoded per `device_type` in
  `devices.py`. There's no field for "which GVL", "array vs scalar", "index
  formula", or "PLC/firmware generation."
- **`DiscoveredCapability`** (`models.py:987-1076`) stores a full
  `raw_var_name` per SuperScan-discovered capability — but this knowledge is
  never consumed by `DeviceRegistry`'s runtime device construction. Two
  disconnected knowledge stores.
- **Real bug, same root cause**: `PLCDevice.ads_port` (`models.py:212-215`)
  exists in the DB but `ADSClient._open_and_verify()`
  (`ads_client.py:200`) hardcodes `pyads.PORT_TC3PLC1` and
  `ADSClient.__init__` (`ads_client.py:100`) doesn't even accept an
  `ads_port` parameter — while `discovery/scanner.py`'s `SymbolScanner`
  *does* honor `dev.ads_port` (`discovery/views.py:121`). The two ADS-talking
  code paths in this codebase disagree with each other.
- **Modbus is a fully parallel, independently hardcoded implementation**:
  `modbus_client.py` exposes a flat point-level API on raw register/coil
  offsets, with its own channel-count constants and its own
  connect/reconnect logic that mirrors but shares zero code with
  `ADSClient`/`devices.py`. `registry.py` glues the two together only via
  hand-written try/except wrappers per read/write method
  (`registry.py:586-663`). Coverage is narrow — only DALI 1-16 and relay 1-4
  have any Modbus path; curtains/switches/sensors/appliances have none.
- **Confirmed-dead-against-real-hardware code**, by the code's own admission:
  `devices.py:24-32`'s module docstring states `ApplianceRelay`,
  `MagneticSensor`, `MotionSensor` (idx 5-8), and `SecurityController` all
  target a `gvlIO` GVL that "doesn't exist in either apartment's TwinCAT
  project" — these only ever worked in `PLC_MOCK` mode, which is now an
  explicit-only opt-in (no more silent automatic fallback, per
  `registry.py:138-141`'s "No mock fallback" comment).

## 2. Documentation: sprawl and one actively misleading file

- **`README.md`** (repo root, the first thing anyone opens) describes a
  **completely different, fictional architecture**: a single
  `Dockerfile.single` mega-container running Postgres+Django+Nginx+Supervisor
  together, container name `plc-app`, one-shot `./auto_deploy.sh` deploy from
  a `PLC_Project` repo root, Flutter using `kBaseUrl`/`API_BASE_URL`/
  `main.dart` with a `10.0.2.2` fallback. **None of this matches reality** —
  confirmed via `git log --oneline -- README.md` showing exactly one commit
  ("initial demo push"), i.e. an unedited scaffold nobody has revisited.
- **`readme_2.md`** contains a real, accurate local-mock-dev walkthrough
  (verified: correct `seed_demo` usage, correct `--dart-define=
  LUGH_SERVER_URL` requirement) mixed with a raw leftover assistant-note
  fragment and one **confirmed-false claim**: "DeviceRegistry automatically
  falls back to mock" on PLC unreachability — directly contradicted by
  `registry.py:138-141`'s explicit "No mock fallback: PLC_MOCK is an
  explicit opt-in" comment. This describes removed behavior.
- **`QUICK_START.md`, `QUICK_START_AUTO.md`, `SERVER_DEPLOYMENT.md`** all
  describe the same fictional single-container/`auto_deploy.sh` architecture
  as old `README.md`.
- **`docs/INFRASTRUCTURE.md` + `infra/helm/`** describe a k3s/Helm deployment
  (host `192.168.0.192`) never referenced by `CLAUDE.md` or
  `docs/DEPLOYMENT_MANUAL.md` (the two docs that match the real, current
  NAS/docker-compose/Cloudflare-Tunnel production setup). Its last commit is
  titled "ggggggggggg". **Confirmed by the project owner (2026-08-24) to be
  dead scaffolding from an earlier direction** — archived, see
  `infra/legacy/` and `docs/legacy/`.
- **`CLAUDE.md`** and **`docs/DEPLOYMENT_MANUAL.md` §7.6** both repeat the
  same stale "PLC variable naming convention" table that matches neither
  `devices.py`'s actual GVLs (`gvlController`, `gvlCurtain`, `gvlIO`) nor
  `classifier.py`'s `_GVL_CATEGORY` vocabulary (`gvldali`, `gvlrelays`,
  `gvlswitch`, ...) — a three-way mismatch between two docs and the code.
- **`docs/plc_proposals/modbus_bridge.md`** (~line 89) claims "Curtains have
  no Django integration at all yet" — contradicted by `devices.py`'s own
  `CurtainMotor` docstring, which documents it was already retargeted to
  `gvlCurtain`/`POU_Curtain`. Doc and code have diverged.
- `CLAUDE.md`'s Key Files table lists `find_device/plc/device_registry.py`;
  the real file is `find_device/plc/registry.py`.

## 3. Secrets/credentials — no real problems found, just scattered

- `.gitignore` correctly excludes `.env`/`.env.*` (with a `!.env.example`
  carve-out).
- `infra/helm/lugh/templates/secrets.yaml` uses proper `CHANGE-ME-*`
  placeholders — correctly designed as a template, not a leaked secret.
- Repo-wide grep for credential-shaped literals found no real committed
  production secrets — only test-fixture passwords in `find_device/tests.py`
  (`"pw12345"`, ~50+ uses across 24 `TestCase` classes — normal Django
  fixture pattern) and the demo-seed password `"Demo12345!"` in
  `seed_demo.py` (clearly local-dev/demo-only).
- **Not yet done**: a full `git log --all --full-history -- .env` sweep for a
  possibly-since-removed committed secret. Flagged as a remaining step (see
  Phase 7 of the implementation plan), not a known problem.
- Admin/dev access today is real and functional but scattered across mental
  models rather than one document: NAS SSH access (in `CLAUDE.md`), `.env`
  per-server, GitHub Actions secrets (enumerated in `CLAUDE.md`), `is_staff`
  app-level gate, `seed_demo` + `PLC_MOCK=True` for zero-hardware local dev.

## 4. Testing — Django is strong, Flutter has zero coverage

- `find_device/tests.py` is 2239 lines, 24 `TestCase` classes: auth gating,
  tenant isolation, DB-driven device-registry construction, security
  endpoints, device-management permissions, general permission enforcement,
  session management, apartment selector, network discovery, registration
  lockdown, user management, apartment management, PLC assignment, room/
  device layout, map API, curtain-motor GVL translation, Modbus-fallback
  registry behavior, PLC heartbeat/alerting, relabel permission/output/input
  flows, building-owner scoping, automation API + execution. Substantial,
  well-organized — preserve as-is.
- `flutter_application_plc/test/**/*.dart` — **zero files**, confirmed via
  glob. No widget tests, no unit tests for `RuntimeConfig`/`AppState`/
  `ApiService`, despite the app having just had a real, serious bug
  (endpoint-failover hammering, fixed in commit `e246b97`) found only
  through manual live testing.

## 5. What's genuinely solid and should not be touched without a strong reason

- `discovery/classifier.py`'s classification logic and `discovery/
  scanner.py`'s dynamic enumeration.
- The 24-class Django test suite.
- `seed_demo.py` + `PLC_MOCK` local dev workflow.
- The Cloudflare multi-endpoint failover system in
  `flutter_application_plc/lib/config/runtime_config.dart` — built and
  hardened this session (see git log `a723e48`..`e246b97`), including a real
  live-verified fix for an endpoint-hammering bug.
- The `ApartmentDevice` model's existing DB-driven device-list pattern
  (replacing a prior hardcoded `APARTMENT_CONFIGS` dict) — direct precedent
  for extending the same pattern to per-device addressing (see
  `docs/plc-integration.md`'s `DeviceAddressScheme` design).
