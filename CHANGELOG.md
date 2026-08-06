# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-08-06

### Added

- `DriverLocation` model (`models/driver_location.dart`): the single shared
  representation of a driver's live position, with an `isFresh()` helper so
  customer, store, and admin apps all agree on when a fix is stale.
  Backs the new `driver_locations` table used for admin/store-side tracking.

## [0.1.0] - 2026-08-06

### Added

- Initial release: shared `OrderStatus` / `PaymentStatus` / `DriverStatus`
  statuses, common order models, and the edge-function helpers
  (`EdgeClient`, `SupabaseStartup`, `edgeTelemetrySink`).
