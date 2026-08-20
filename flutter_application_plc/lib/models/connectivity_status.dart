/// Why the app currently can't (or can) trust the device state it's
/// showing — the classification the old bare `connected` bool collapsed
/// into a single "Offline / Check settings" message regardless of cause.
/// Each value maps to a specific, actionable message; see
/// AppState._classifyConnectivity for how a poll result becomes one of
/// these, and dashboard_screen.dart's connection card for how each one is
/// worded for a resident.
enum ConnectivityStatus {
  ok,
  connecting,

  /// Can't reach the server at all — no route, DNS failure, timeout.
  serverUnreachable,

  /// Server reachable, but this session's login token is invalid/expired.
  authFailure,

  /// Server reachable, authenticated, but this account has no apartment
  /// assigned yet (backend code NO_APARTMENT) — a real account-setup gap,
  /// not a network problem.
  noApartment,

  /// Server reachable, authenticated, but this account lacks permission
  /// for the specific thing it just tried (backend code FORBIDDEN).
  forbidden,

  /// Server reachable but asked us to slow down (HTTP 429).
  rateLimited,

  /// Server reachable, request reached it, but it failed unexpectedly
  /// (5xx / SERVER_ERROR) — a backend bug or outage, not a connectivity
  /// problem on the phone's end.
  serverError,

  /// Server reachable and responded, but the response body wasn't the
  /// JSON we expected — a version mismatch or a proxy/gateway page
  /// (e.g. Cloudflare's own error HTML) instead of the real API response.
  invalidResponse,

  /// Server reachable and the request succeeded, but the PLC itself is
  /// disconnected (plc_connected:false in the payload) — every device
  /// reading this poll is stale/unknown, not necessarily off.
  plcDown,
}

extension ConnectivityStatusX on ConnectivityStatus {
  bool get isHealthy => this == ConnectivityStatus.ok;

  /// True whenever device state readings should be trusted at face value.
  /// Every other status means "don't render a confident ON/OFF."
  bool get devicesTrustworthy => this == ConnectivityStatus.ok;

  /// Short badge text — Home screen connection card, System Status row.
  String get shortLabel => switch (this) {
        ConnectivityStatus.ok => 'Connected',
        ConnectivityStatus.connecting => 'Connecting…',
        ConnectivityStatus.serverUnreachable => 'Offline',
        ConnectivityStatus.authFailure => 'Sign-in expired',
        ConnectivityStatus.noApartment => 'No apartment assigned',
        ConnectivityStatus.forbidden => 'Access restricted',
        ConnectivityStatus.rateLimited => 'Slow down',
        ConnectivityStatus.serverError => 'Server error',
        ConnectivityStatus.invalidResponse => 'Unexpected response',
        ConnectivityStatus.plcDown => 'Hardware unreachable',
      };

  /// One sentence: what happened, in plain language a resident understands
  /// — no exception text, no error codes.
  String get message => switch (this) {
        ConnectivityStatus.ok => 'Connected.',
        ConnectivityStatus.connecting => 'Connecting to your home…',
        ConnectivityStatus.serverUnreachable =>
          "Can't reach the server. Check your internet connection.",
        ConnectivityStatus.authFailure =>
          'Your session has expired. Please sign in again.',
        ConnectivityStatus.noApartment =>
          "Your account isn't linked to an apartment yet.",
        ConnectivityStatus.forbidden =>
          "You don't have access to do that.",
        ConnectivityStatus.rateLimited =>
          'Too many requests — please wait a moment.',
        ConnectivityStatus.serverError =>
          'Something went wrong on our end. Please try again shortly.',
        ConnectivityStatus.invalidResponse =>
          'Got an unexpected response from the server.',
        ConnectivityStatus.plcDown =>
          "The server is up, but your home's controller isn't responding. "
              'Device states below may be out of date.',
      };

  /// What the resident can actually do about it, when there's a concrete
  /// action — null when there isn't one (e.g. plcDown just needs to wait).
  String? get action => switch (this) {
        ConnectivityStatus.serverUnreachable => 'Try again, or check Settings for the server address.',
        ConnectivityStatus.authFailure => 'Sign out and sign back in.',
        ConnectivityStatus.noApartment => 'Contact your building manager.',
        ConnectivityStatus.forbidden => 'Contact your building manager if this seems wrong.',
        ConnectivityStatus.rateLimited => null,
        ConnectivityStatus.serverError => 'If this keeps happening, contact your building manager.',
        ConnectivityStatus.invalidResponse => 'If this keeps happening, contact your building manager.',
        _ => null,
      };
}
