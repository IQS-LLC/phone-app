# Lugh — Flutter App

The mobile client for Lugh, a smart-building control platform. Talks to the
Django backend in `../find_device/` over HTTPS/JWT. See the repo root
[`README.md`](../README.md) and [`docs/`](../docs/) for the full system
picture — this file covers only what's specific to the Flutter app.

## Running it

The login screen has no visible server-address field by design (see
`lib/config/runtime_config.dart`'s doc comment — a deliberate
anti-phishing decision). The server address is baked in at build/launch time
via `--dart-define=LUGH_SERVER_URL`, and accepts a comma-separated list (the
multi-endpoint Cloudflare failover pool used in production).

```bash
flutter pub get
flutter run --dart-define=LUGH_SERVER_URL=http://127.0.0.1:8000
```

See [`../docs/dev-environment.md`](../docs/dev-environment.md) for the full
local-dev walkthrough (no PLC hardware required), including how to run
against a mock-PLC backend on the same machine.

## Architecture (client side)

- `lib/config/runtime_config.dart` — the single source of truth for the
  server URL. Owns the multi-endpoint failover pool: health tracking,
  circuit breaker, exponential backoff, automatic promotion/reclaim between
  endpoints. Every other service reads the current URL from here; nothing
  else is allowed to cache its own copy (see the file's doc comment for the
  real bug that made this rule necessary).
- `lib/state/app_state.dart` — the app's live device/connectivity state,
  polling the backend roughly once a second and reconciling optimistic UI
  updates against confirmed server state.
- `lib/auth/` — JWT login/session handling.
- `lib/services/api_service.dart` — the HTTP layer; classifies every failure
  into an `ApiErrorCode` that `RuntimeConfig` uses to decide whether an
  endpoint is unhealthy.
- `lib/screens/` — one file per screen; `main_shell.dart` is the tab
  navigation root.

## Role-based UI

The app shows/hides features based on what the backend's `/auth/` response
says about the logged-in user (`is_staff`, apartment membership role) — the
Flutter code never makes its own authorization decisions, it only reflects
what the backend already decided. See the repo root `CLAUDE.md`'s Role
System table for the full breakdown.

## Testing

As of the 2026-08-24 audit, this app has **no automated tests** — see
`docs/AUDIT_FINDINGS.md` §4 and `docs/testing.md` (once written) for the plan
to add coverage around the highest-risk logic (`RuntimeConfig`'s failover
state machine, `AppState`'s stale-response guarding, `ApiService`'s error
classification). If you're adding a test file, it belongs under `test/` at
this package's root, using plain `flutter_test`.
