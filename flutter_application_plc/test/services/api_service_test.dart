// Tests for ApiService.exceptionToResult — the exception-to-ApiErrorCode
// classification that RuntimeConfig.reportOutcome's failover decisions
// depend on entirely (see runtime_config_test.dart's
// "endpoint-health classification" group, which assumes these codes are
// assigned correctly upstream). A misclassification here would silently
// break failover without either piece of code looking wrong on its own —
// exactly the kind of seam covered in docs/AUDIT_FINDINGS.md.
//
// exceptionToResult was made public + @visibleForTesting (was
// _exceptionToResult) specifically to make this test possible — see its
// doc comment in api_service.dart. It's a pure static function (no
// network, no ApiService instance needed), so this needs no HTTP mocking.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_plc/services/api_service.dart';

void main() {
  group('ApiService.exceptionToResult', () {
    test('SocketException classifies as network, never shows raw exception text', () {
      final result = ApiService.exceptionToResult(
        const SocketException('Failed host lookup: some-tunnel.trycloudflare.com'),
        123,
      );
      expect(result.errorCode, ApiErrorCode.network);
      expect(result.isNetwork, isTrue);
      expect(result.success, isFalse);
      expect(result.latencyMs, 123);
      // The exact 2026-08-20 regression this guards against: a raw
      // exception string (host/DNS detail) must never end up in the
      // user-facing message.
      expect(result.errorMessage, isNot(contains('trycloudflare')));
      expect(result.errorMessage, isNot(contains('SocketException')));
    });

    test('TimeoutException classifies as timeout', () {
      final result = ApiService.exceptionToResult(TimeoutException('too slow'), 5000);
      expect(result.errorCode, ApiErrorCode.timeout);
      expect(result.isTimeout, isTrue);
    });

    test('FormatException (bad JSON) classifies as parseError', () {
      final result = ApiService.exceptionToResult(const FormatException('Unexpected character'), 50);
      expect(result.errorCode, ApiErrorCode.parseError);
    });

    test('an unrecognized exception type falls back to unknown, with a safe generic message', () {
      final result = ApiService.exceptionToResult(Exception('some http.ClientException wrapping detail'), 10);
      expect(result.errorCode, ApiErrorCode.unknown);
      expect(result.errorMessage, "Can't reach the server. Check your connection.");
      // The raw detail must still be captured somewhere for diagnostics —
      // just not in the user-facing message.
      expect(result.debugDetail, contains('ClientException'));
    });

    test('a null exception (defensive case) still returns a safe unknown result, not a crash', () {
      expect(() => ApiService.exceptionToResult(null, 0), returnsNormally);
      final result = ApiService.exceptionToResult(null, 0);
      expect(result.errorCode, ApiErrorCode.unknown);
    });

    test('every non-success result carries a null statusCode (never reached the server)', () {
      // Distinguishes a network-level failure from a real HTTP response —
      // RuntimeConfig/AppState's connectivity classification depends on
      // statusCode being genuinely absent here, not a guessed value.
      for (final e in [const SocketException('x'), TimeoutException('x'), const FormatException('x')]) {
        final result = ApiService.exceptionToResult(e, 1);
        expect(result.statusCode, isNull);
      }
    });
  });
}
