// Tests for RuntimeConfig's multi-endpoint failover state machine — the
// highest-priority gap identified in docs/AUDIT_FINDINGS.md and
// docs/testing.md: this logic had zero test coverage despite a real,
// serious bug (endpoint-failover hammering a fully-down pool every 1-3s)
// having been found here, by hand, in production. See runtime_config.dart's
// own doc comment for the full design this exercises.
//
// Scope, deliberately: RuntimeConfig is a hard singleton (private
// constructor, `RuntimeConfig._()`) and its background prober
// (`_probeBackups`/`_probeOne`) calls the top-level `http.get()` directly
// rather than through an injectable client — neither is mockable without
// changing production code, which is out of scope for adding tests. These
// tests drive everything through the same public surface real callers use
// (`setEndpoints`, `reportOutcome`, and the public getters) and never call
// `initialize()` — that's the one method that starts the real background
// Timer, which would make genuine network calls during a test run. The
// legacy-single-URL migration path inside `initialize()` and the actual
// HTTP probing in `_probeOne` are therefore NOT covered here; everything
// else — circuit breaker, backoff-driven promotion, the all-down fallback,
// sticky reclaim, and the endpoint-health classification rules — is.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_application_plc/config/runtime_config.dart';
import 'package:flutter_application_plc/services/api_service.dart' show ApiErrorCode;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final config = RuntimeConfig.instance;

  // RuntimeConfig is a singleton — every real caller shares this one
  // instance, so these tests do too. setEndpoints() fully replaces the
  // pool and resets _activeIndex/version bookkeeping, which is what gives
  // each test a known-clean starting point without needing a fresh
  // instance (impossible anyway, given the private constructor).
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await config.setEndpoints([
      'https://a.example.com',
      'https://b.example.com',
      'https://c.example.com',
    ]);
  });

  group('reportOutcome endpoint-health classification', () {
    test('network/timeout/serverError count as endpoint failures', () async {
      for (final code in [ApiErrorCode.network, ApiErrorCode.timeout, ApiErrorCode.serverError]) {
        await config.setEndpoints(['https://a.example.com', 'https://b.example.com']);
        for (var i = 0; i < 3; i++) {
          config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: code);
        }
        final a = config.endpoints.firstWhere((e) => e.url == 'https://a.example.com');
        expect(a.isHealthy, isFalse, reason: '$code should open the circuit after 3 failures');
      }
    });

    test('clientError (401/403/429/NO_APARTMENT-equivalent) never counts as an endpoint failure', () async {
      // Many more than the 3-failure threshold — if this were misclassified
      // as an endpoint signal, the circuit would already be open.
      for (var i = 0; i < 10; i++) {
        config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.clientError);
      }
      final a = config.endpoints.firstWhere((e) => e.url == 'https://a.example.com');
      expect(a.isHealthy, isTrue,
          reason: 'a 401/403/429-class response is identical on every endpoint '
              '(same backend) and must never trigger failover');
      // The active endpoint must also still be the one we started on —
      // client errors must never cause a promotion either.
      expect(config.serverUrl, 'https://a.example.com');
    });

    test('a report for a URL no longer in the pool is silently ignored, not an error', () {
      expect(
        () => config.reportOutcome(url: 'https://not-in-pool.example.com', success: false, errorCode: ApiErrorCode.network),
        returnsNormally,
      );
    });

    test('exactly 2 consecutive failures does not yet open the circuit', () {
      config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      final a = config.endpoints.firstWhere((e) => e.url == 'https://a.example.com');
      expect(a.isHealthy, isTrue);
    });

    test('a success resets the failure count, so 2 failures + success + 2 failures never opens the circuit', () {
      config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      config.reportOutcome(url: 'https://a.example.com', success: true);
      config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      final a = config.endpoints.firstWhere((e) => e.url == 'https://a.example.com');
      expect(a.isHealthy, isTrue);
    });
  });

  group('automatic failover / promotion', () {
    test('3 consecutive failures on the active endpoint promotes the next healthy one', () {
      final startVersion = config.version;
      expect(config.serverUrl, 'https://a.example.com');

      for (var i = 0; i < 3; i++) {
        config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      }

      expect(config.serverUrl, 'https://b.example.com',
          reason: 'the active endpoint tripping its circuit must promote the next '
              'closed-circuit candidate in priority order');
      expect(config.version, startVersion + 1,
          reason: 'version must bump exactly once for this one failover, so '
              'AppState\'s stale-response guard sees it');
    });

    test('failing the same endpoint again after it is already inactive does not re-promote', () {
      for (var i = 0; i < 3; i++) {
        config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      }
      expect(config.serverUrl, 'https://b.example.com');
      final versionAfterFirstFailover = config.version;

      // A late-arriving failure report for the now-inactive endpoint 'a'
      // must not disturb 'b', which is currently active and untested.
      config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      expect(config.serverUrl, 'https://b.example.com');
      expect(config.version, versionAfterFirstFailover);
    });

    test('every endpoint down still leaves serverUrl valid and sets activeEndpointCoolingDown', () async {
      await config.setEndpoints(['https://a.example.com', 'https://b.example.com']);
      expect(config.activeEndpointCoolingDown, isFalse);

      // Drive both endpoints into an open circuit via whichever is active
      // at the time — mirrors a real total outage where every endpoint
      // fails in turn.
      for (var round = 0; round < 6; round++) {
        config.reportOutcome(url: config.serverUrl, success: false, errorCode: ApiErrorCode.network);
      }

      expect(['https://a.example.com', 'https://b.example.com'], contains(config.serverUrl),
          reason: 'must still resolve to a real pool member, never null/empty, '
              'even when every endpoint is unhealthy');
      expect(config.activeEndpointCoolingDown, isTrue,
          reason: 'this is exactly the flag AppState._doPoll() checks to avoid '
              'hammering a known-dead endpoint every ~1-3s — see '
              'docs/AUDIT_FINDINGS.md for the real bug this prevents');
    });
  });

  group('sticky reclaim', () {
    test('a single clean report for a higher-priority endpoint does not reclaim it', () {
      for (var i = 0; i < 3; i++) {
        config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      }
      expect(config.serverUrl, 'https://b.example.com');

      // Only one success for 'a' — reclaim requires several consecutive
      // ones (deliberately conservative, to avoid flapping on one lucky
      // probe of a genuinely flaky endpoint).
      config.reportOutcome(url: 'https://a.example.com', success: true);
      expect(config.serverUrl, 'https://b.example.com',
          reason: 'reclaim must not fire on the first sign of life');
    });

    test('several consecutive clean reports for a higher-priority endpoint reclaims it', () {
      for (var i = 0; i < 3; i++) {
        config.reportOutcome(url: 'https://a.example.com', success: false, errorCode: ApiErrorCode.network);
      }
      expect(config.serverUrl, 'https://b.example.com');
      final versionAfterFailover = config.version;

      for (var i = 0; i < 3; i++) {
        config.reportOutcome(url: 'https://a.example.com', success: true);
      }

      expect(config.serverUrl, 'https://a.example.com',
          reason: 'sustained proof that the higher-priority endpoint recovered '
              'should migrate back to it');
      expect(config.version, versionAfterFailover + 1);
    });
  });

  group('setEndpoints', () {
    test('replacing the pool with an identical list is a no-op (no version bump)', () async {
      final before = config.version;
      final err = await config.setEndpoints([
        'https://a.example.com', 'https://b.example.com', 'https://c.example.com',
      ]);
      expect(err, isNull);
      expect(config.version, before,
          reason: 'callers should be able to call this unconditionally without '
              'triggering a spurious reconnect for an unchanged pool');
    });

    test('an invalid URL is rejected with a user-facing message and changes nothing', () async {
      final before = config.serverUrl;
      final err = await config.setEndpoints(['not a url']);
      expect(err, isNotNull);
      expect(config.serverUrl, before);
    });

    test('an empty list is rejected', () async {
      final err = await config.setEndpoints([]);
      expect(err, isNotNull);
    });

    test('duplicate URLs in the input are deduplicated', () async {
      await config.setEndpoints(['https://x.example.com', 'https://x.example.com']);
      expect(config.endpointCount, 1);
    });

    test('setServerUrl replaces the entire pool with just the one URL', () async {
      final err = await config.setServerUrl('https://solo.example.com');
      expect(err, isNull);
      expect(config.endpointCount, 1);
      expect(config.serverUrl, 'https://solo.example.com');
    });
  });
}
