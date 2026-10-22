# Phase B TODO — Dispatch Offer Timeout (Seconds)

Contract: `docs/phase_b_contract.md` (customer app repo).
Deploy + smoke test: [docs/phase_b_deploy_and_smoke.md](docs/phase_b_deploy_and_smoke.md).

## Steps

1. [x] Confirm remote schema
   - Read live through the Supabase connector on 2026-10-11 (project
     `lxsvydiyzeavdqbjxkpp`). `public.driver_assignments` already had
     `id, order_id, driver_id, status, notes, accepted_at, picked_up_at,
     delivered_at, cancelled_at, created_at, updated_at, current_lat,
     current_lng, last_location_update, location_accuracy, location_speed,
     location_heading`.
   - `status` is unconstrained `text` with default `'assigned'` and live values
     `assigned` / `delivered` / `Picked up`, so `offered` needs no
     status-vocabulary migration and no `CHECK` constraint was added.
   - `notifications` has `UNIQUE (order_id, user_id, type) WHERE order_id IS NOT
     NULL`, so the sweep upserts against it instead of de-duping with a read.
   - `pg_cron`, `pg_net`, `postgis`, `supabase_vault` installed; five existing
     `qai_*` cron jobs call SQL functions directly. The sweep follows that
     convention.

2. [x] Migration — **applied to the live project**
   - [lib/supabase/migrations/20261011_phase_b_dispatch_offers.sql](lib/supabase/migrations/20261011_phase_b_dispatch_offers.sql)
   - Additive and idempotent. Offer columns `offer_expires_at timestamptz` +
     `timeout_seconds integer` (with a positivity check), applied to live
     `driver_assignments`; existing rows keep NULL offer fields.
   - `driver_assignment_status_is_active(text)` — one shared definition of which
     assignment statuses are still live (terminal: `delivered`, `cancelled`,
     `canceled`, `expired`, `declined`, `failed`, `failed_delivery`,
     `rejected`).
   - `driver_assignments_one_active_per_order_idx` — unique partial index so
     **only one driver can win an order**. This is the concurrency fix: the
     driver app used to check-then-insert with only `(order_id, driver_id,
     status)` uniqueness, so two drivers could both insert.
   - Live-offer expiry index + `driver_assignments` added to
     `supabase_realtime` so offers reach drivers live.
   - `dispatch_offer_timeout_seconds()`, `nearby_eligible_drivers(...)`,
     `create_dispatch_offer(...)`, `accept_dispatch_offer(uuid)`,
     `decline_dispatch_offer(uuid, text)`, `enforce_dispatch_offer_timeout()`.
   - Grants: the sweep is `service_role` only; the driver-facing RPCs are
     `authenticated` + `service_role`; `anon` is revoked everywhere.
   - Applied via the connector on 2026-10-11 and verified in the catalog (all
     seven functions present, both indexes present, realtime publication set).

3. [x] Expiry sweep — now ONE implementation, in SQL
   - `public.enforce_dispatch_offer_timeout()` returns
     `(offers_stamped, offers_expired, orders_requeued, notifications_sent)`.
   - Pass 1 stamps `offer_expires_at = created_at + timeout_seconds` on any
     `offered` row without an expiry.
   - Pass 2 clears lapsed offers: assignment → `expired`, order →
     `ready_for_pickup`, one timeline entry, one customer notification
     (upserted on the notifications unique key). It only requeues when nothing
     live is left on the order.
   - Idempotent: both passes are status-guarded, and the notification upsert
     makes a re-run a no-op rather than a duplicate.
   - [supabase/functions/enforce-dispatch-offer-timeout/index.ts](supabase/functions/enforce-dispatch-offer-timeout/index.ts)
     is now a **thin HTTP wrapper** over that SQL function: `GET` probes the
     configured timeout, `POST` runs the sweep, service-role bearer required
     (401 otherwise, 405 for other methods). It contains no dispatch rules, so
     the HTTP path and the cron path cannot drift. The former
     `dispatchOffer.ts` helper was deleted with the duplicated logic.
   - **Not deployed** — nothing has been pushed from this environment.

4. [x] Config
   - The timeout is a database setting read by
     `dispatch_offer_timeout_seconds()`: default **60**, floor 1, overridable
     with `alter database postgres set app.dispatch_offer_timeout_seconds = '90';`.
     No secret and no env var is involved.
   - Deliberately **not** duplicated into the apps: the driver screen derives its
     countdown from `offer_expires_at` / `timeout_seconds` on the row, so the
     server owns the deadline.

5. [ ] Driver app (`queless_driver`) — not in this repo
   - **Confirm `driver_locations` is actually populated on device.** The publish
     path already exists (`publishLocation` upserts `driver_locations` in
     `lib/services/order_service.dart`), but the table has 0 rows, and
     `nearby_eligible_drivers` requires a position seen in the last 15 minutes —
     so today dispatch matches nobody, at any radius. RLS is not the cause — the
     table has `driver_upserts_own_location` for `authenticated` and every column
     the app writes exists (checked 2026-10-11) — so the likeliest reading is
     that no driver has published since the table was created. The wrapping
     `catch` from `order_service.dart` treats any failure as non-critical, which
     would hide it if that changes.
   - **Accept/decline now go through the RPCs** (`order_service.dart`):
     `acceptOrder` accepts an open offer via `accept_dispatch_offer`, and the
     old "update every row for this order" branch is gone because the unique
     index would reject it. Direct claims insert and let the index arbitrate.
   - **Offer UI is in place** (`order_details_screen.dart`): a countdown banner
     driven by the server's `offer_expires_at`, a DECLINE button, and a realtime
     subscription that makes an offer appear or clear itself.
   - Not runtime-verified: it is analyse-verified only, and no offer can reach a
     device until `driver_locations` has rows.

6. [ ] Customer app (`queless-v1.0.1`) — not in this repo
   - Render the appended `orders.tracking_updates` entry. No dispatch-offer
     action by design.

7. [x] Shared types (queless_core)
   - [lib/models/driver_assignment.dart](lib/models/driver_assignment.dart):
     `DriverAssignmentStatus` vocabulary (`offered`, `expired`, `declined`,
     `assigned`), `offerExpiresAt`, `timeoutSeconds`, `isPendingOffer`,
     `isOfferedStatus`, `isExpiredOfferStatus`, `isDeclinedOfferStatus`,
     `isClosedOfferStatus`, `isOfferExpiredAt` / `isOfferExpired`,
     `offerRemainingAt` / `offerRemaining`, `canRespondToOfferAt` /
     `canRespondToOffer`.
   - Each member exists exactly once; no duplicate getters remain.
   - Covered by [test/driver_assignment_offer_test.dart](test/driver_assignment_offer_test.dart)
     (9 tests, `flutter test` green, `flutter analyze` clean).

8. [x] Automatic dispatch — **applied live, trigger + cron active**
   - [lib/supabase/migrations/20261011_phase_b_auto_dispatch.sql](lib/supabase/migrations/20261011_phase_b_auto_dispatch.sql)
   - A trigger dispatches the moment an order becomes `ready_for_pickup`; the
     `queless-dispatch-tick` cron job (every minute) clears lapsed offers and
     retries the orders still waiting.
   - Origin: `stores.store_location` when set, else the customer's
     `delivery_address` point. Only 2 of 16 stores have coordinates and no store
     `delivery_polygon` exists, so today drivers are ranked by distance to the
     customer, capped by `stores.delivery_radius_km`.
   - Verified live on 2026-10-11 inside a rolled-back transaction (trigger
     offered to the nearest of two seeded drivers, a decline excluded that
     driver and the retry reached the other, radius capped by the store's 5 km),
     and the scheduled tick has been observed succeeding.

9. [ ] Deploy the HTTP wrapper + run the smoke test
   - The migrations are already live; what remains (deploy
     `enforce-dispatch-offer-timeout`, run the smoke test) is in
     [docs/phase_b_deploy_and_smoke.md](docs/phase_b_deploy_and_smoke.md).

## Companion change — done

`supabase/functions/orders-status/index.ts` (in `queless-v1.0.1`) had two
unfiltered single-row reads of `driver_assignments`. Both now resolve the live
assignment through a `fetchLiveAssignment(orderId)` helper that ignores terminal
statuses, so they cannot break once an order has expired or declined offers
behind it. The deploy doc explains why it filters in TypeScript rather than with
`.in("status", [...])`.

## Out of scope for Phase B
- Manual driver picking (store/admin choosing a specific driver from a list).
  Auto-dispatch was implemented instead; `create_dispatch_offer` can still be
  called by hand for an override.
- Customer-side dispatch offer action (customer only watches timeline).
- Explicit hand-off between couriers mid-delivery (the loop only ever re-offers
  an order that was never accepted).
