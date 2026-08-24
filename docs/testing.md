# Testing

## Backend (Django) — run it

```bash
python manage.py test --verbosity=2
```

This is the exact command CI runs (`.github/workflows/deploy.yml`'s `test`
job), against a real PostgreSQL service container, not sqlite — a test
passing locally against a different DB engine is not the same guarantee.

## Backend coverage — what's actually tested

`find_device/tests.py` (2239 lines, 24 `TestCase` classes as of the
2026-08-24 audit) covers: auth gating, tenant isolation, DB-driven device
registry construction, security endpoints, device-management permissions,
general permission enforcement, session management, apartment selector,
network discovery, registration lockdown, user management, apartment
management, PLC device assignment, room/device layout, the map API,
curtain-motor GVL translation, Modbus-fallback registry behavior, PLC
heartbeat/alerting, relabel permission/output/input flows, building-owner
scoping, and automation API + execution. This is genuinely substantial —
when adding a new backend feature, look for the closest existing
`TestCase` class first; there's a good chance the pattern you need (minting
a JWT for a given role, building a test apartment/device fixture) already
exists there.

**Known gap, not yet confirmed either way**: `find_device/plc/ads_client.py`'s
own reconnect/backoff logic in isolation. The test suite is strong on
permissions/DB/registry-construction; this specific low-level retry
behavior hasn't been independently verified by a dedicated test as of this
writing.

## Frontend (Flutter) — currently zero coverage

`flutter_application_plc/test/` has no files. This matters concretely: a
real, serious bug (the multi-endpoint failover system hammering a dead
tunnel pool every 1-3 seconds — see `docs/AUDIT_FINDINGS.md`) was found only
through manual live testing on an emulator, not by any automated check.

**Priority order for adding coverage** (all pure state-machine logic, no
widget-rendering dependency — cheap to unit-test with plain `flutter_test`,
already a pubspec dependency):

1. **`lib/config/runtime_config.dart`** — the endpoint-pool failover state
   machine. Test: circuit breaker opening after 3 consecutive failures,
   exponential backoff's jitter bounds, endpoint-selection order (including
   the "every endpoint down" fallback), the sticky reclaim-after-N-probes
   behavior, and — the single most important one — `reportOutcome`'s
   classification of which error types count as an endpoint-health signal
   (a 401/403/429 must never trigger failover; a network/timeout/5xx
   always should). Getting this classification wrong silently breaks
   failover in a way that's easy to miss in manual testing.
2. **`lib/state/app_state.dart`** — the stale-response-discard guard
   (`requestVersion != _config.version`). This exact bug class has recurred
   multiple times in this project's git history; a test that proves a
   response arriving after a config-version bump gets discarded (not
   applied) would catch a regression before it ships.
3. **`lib/services/api_service.dart`** — the exception-to-error-code
   mapping that `RuntimeConfig.reportOutcome` depends on for correct
   failover decisions.

Use `shared_preferences`'s test-mode in-memory implementation and a fake
`http.Client` — no new dependencies needed to start on any of the above.

## Before calling anything "done"

Per this project's own working principle: passing tests are necessary, not
sufficient. For anything touching the PLC/device layer or the mobile app's
connectivity handling, also do a real manual pass — install the actual
build, log in as more than one role, and induce at least one real failure
(kill a tunnel, disconnect the PLC) rather than trusting that green tests
alone mean the feature works end-to-end.
