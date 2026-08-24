# Testing

## Backend (Django) — run it

```bash
python manage.py test --verbosity=2
```

This is the exact command CI runs (`.github/workflows/deploy.yml`'s `test`
job), against a real PostgreSQL service container, not sqlite — a test
passing locally against a different DB engine is not the same guarantee.

## Backend coverage — what's actually tested

`find_device/tests.py` (26 `TestCase` classes, 162 tests as of the
2026-08-24 Phase 4 work) covers: auth gating, tenant isolation, DB-driven device
registry construction, security endpoints, device-management permissions,
general permission enforcement, session management, apartment selector,
network discovery, registration lockdown, user management, apartment
management, PLC device assignment, room/device layout, the map API,
curtain-motor GVL translation, Modbus-fallback registry behavior, PLC
heartbeat/alerting, relabel permission/output/input flows, building-owner
scoping, automation API + execution, the `DeviceAddressScheme`/
`TemplatedDevice` data-driven addressing path (including a real read/write
round-trip through the registry in mock mode, and that a malformed template
fails loud rather than silently addressing the wrong variable), and the
SuperScan-capability-to-managed-device promote endpoint. This is genuinely
substantial — when adding a new backend feature, look for the closest
existing `TestCase` class first; there's a good chance the pattern you need (minting
a JWT for a given role, building a test apartment/device fixture) already
exists there.

**Known gap, not yet confirmed either way**: `find_device/plc/ads_client.py`'s
own reconnect/backoff logic in isolation. The test suite is strong on
permissions/DB/registry-construction; this specific low-level retry
behavior hasn't been independently verified by a dedicated test as of this
writing.

## Frontend (Flutter) — was zero coverage; now covers the two highest-risk pieces

`flutter_application_plc/test/` had no files until 2026-08-24. A real,
serious bug (the multi-endpoint failover system hammering a dead tunnel
pool every 1-3 seconds — see `docs/AUDIT_FINDINGS.md`) was found only
through manual live testing on an emulator, not by any automated check —
that's what prompted closing this gap.

**Done:**

1. **`test/config/runtime_config_test.dart`** (15 tests) — the endpoint-pool
   failover state machine: circuit breaker opening after 3 consecutive
   failures (and *not* after 2), `reportOutcome`'s classification of which
   error types count as an endpoint-health signal (confirmed: a
   401/403/429-class `clientError` never trips the breaker even after 10
   failures; `network`/`timeout`/`serverError` always do after 3),
   automatic promotion to the next healthy endpoint with a single `version`
   bump, the "every endpoint down" fallback (confirmed `serverUrl` stays a
   real pool member and `activeEndpointCoolingDown` flips true — the exact
   flag that gates `AppState`'s poller and prevents the hammering bug from
   recurring), and the sticky reclaim-after-3-probes behavior (confirmed
   one clean report does *not* reclaim, three consecutive ones do).
2. **`test/services/api_service_test.dart`** (6 tests) — the
   exception-to-`ApiErrorCode` classification `RuntimeConfig.reportOutcome`
   depends on for correct failover decisions: `SocketException`→`network`,
   `TimeoutException`→`timeout`, `FormatException`→`parseError`, an
   unrecognized exception→`unknown` with a safe generic message (and
   specifically confirms raw exception text — the 2026-08-20 regression —
   never leaks into the user-facing string), and that a `null` exception
   doesn't crash. Required making `ApiService._exceptionToResult` public as
   `exceptionToResult` with `@visibleForTesting` (no behavior change — see
   its doc comment) since it was a private pure function with no other
   testable seam.

**Deliberately not done, and why**: `AppState`'s stale-response-discard
guard (`requestVersion != _config.version` in `_doPoll()`) is real,
important, and has recurred as a bug class multiple times in this
project's git history — but `AppState` constructs its own `ApiService`
internally rather than accepting an injectable one, and `ApiService` itself
calls the top-level `http.get`/`http.post` rather than an injectable
`http.Client`. Testing the actual race (a response arriving *after* a
version bump gets discarded) deterministically would need either a real
network call with unpredictable timing, or adding dependency injection to
already-hardened, live-verified polling code — a production refactor
beyond "add tests for existing behavior." The guard itself is simple, has
been read and verified by hand, and is exercised implicitly by live testing
every time a tunnel fails over mid-poll (this project has done that
repeatedly this session). If `AppState` ever gains an injectable API layer
for other reasons, add this test then — don't add the seam solely to
enable it.

Both new test files use `shared_preferences`'s test-mode in-memory
implementation (`SharedPreferences.setMockInitialValues`) — no new
dependencies were needed. Run them with `flutter test` from
`flutter_application_plc/`.

## Before calling anything "done"

Per this project's own working principle: passing tests are necessary, not
sufficient. For anything touching the PLC/device layer or the mobile app's
connectivity handling, also do a real manual pass — install the actual
build, log in as more than one role, and induce at least one real failure
(kill a tunnel, disconnect the PLC) rather than trusting that green tests
alone mean the feature works end-to-end.
