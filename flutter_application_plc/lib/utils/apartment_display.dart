/// Centralizes how an apartment's human-readable name is derived for
/// display. One rule, enforced in exactly one place: never synthesize a
/// name-shaped string from `apartment.id`, and never assume the backend's
/// `name` field needs an "Apartment " prefix added.
///
/// Found live 2026-08-20, two separate bugs from screens each building
/// their own fallback independently:
///   - the dashboard hero banner and Map Mode's top badge both fell back to
///     `'Apartment $apartmentId'` while the real name was still loading —
///     apartment PK 1 happens to be named "Apartment 16" in this dataset,
///     while a *different* apartment is genuinely named "Apartment 8", so
///     the fallback rendered a plausible-looking but WRONG apartment name
///     instead of an obvious placeholder.
///   - Map Mode separately prepended "Apartment " to `authState.apartmentName`,
///     which is already the full display name, producing
///     "Apartment Apartment 16".
///
/// [label] is the single choke point every screen must route through
/// instead of writing its own `?? 'Apartment $x'` or `'Apartment $name'`.
class ApartmentDisplay {
  ApartmentDisplay._();

  /// [name] is the backend's own display name for the apartment — it
  /// already includes any "Apartment" word the installer gave it, so never
  /// prepend one here, and never fall back to a numeric id.
  static String label(String? name) =>
      (name != null && name.trim().isNotEmpty) ? name : 'Loading…';
}
