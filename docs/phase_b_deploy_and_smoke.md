# Phase B — Dispatch Offer Timeout: deploy + smoke test plan

Phase B makes a dispatch offer time-boxed in **seconds**: the driver accepts or
declines before the deadline, and an unanswered offer is cleared so the order
goes back to the queue.

- Contract: `docs/phase_b_contract.md` in the customer app repo (`queless-v1.0.1`)
  — it is not part of this repo, so it is named rather than linked.
- Checklist: [`TODO_phase_b.md`](../TODO_phase_b.md)

Target project: `lxsvydiyzeavdqbjxkpp` (`queless`). The remote schema was read
through the Supabase connector on 2026-10-11 and the migration was applied to
that project the same day — see the migration header for the exact column list.

## What ships

| Artifact | Path | State |
| --- | --- | --- |
| Migration: offer columns, unique live-assignment index, dispatch RPCs, sweep | [`lib/supabase/migrations/20261011_phase_b_dispatch_offers.sql`](../lib/supabase/migrations/20261011_phase_b_dispatch_offers.sql) | **applied live** |
| Migration: automatic dispatch (trigger + tick) | [`lib/supabase/migrations/20261011_phase_b_auto_dispatch.sql`](../lib/supabase/migrations/20261011_phase_b_auto_dispatch.sql) | **applied live, tick scheduled** |
| HTTP wrapper around the sweep | [`supabase/functions/enforce-dispatch-offer-timeout/index.ts`](../supabase/functions/enforce-dispatch-offer-timeout/index.ts) | not deployed |
| Function config (`verify_jwt = false`) | [`supabase/functions/enforce-dispatch-offer-timeout/config.toml`](../supabase/functions/enforce-dispatch-offer-timeout/config.toml) | — |
| Shared model + offer vocabulary | [`lib/models/driver_assignment.dart`](../lib/models/driver_assignment.dart) | done |
| Shared model tests | [`test/driver_assignment_offer_test.dart`](../test/driver_assignment_offer_test.dart) | done |

The sweep exists **once**, as the SQL function
`public.enforce_dispatch_offer_timeout()`. The edge function is only a
service-role-gated HTTP trigger for it (`GET` = config probe, `POST` = run), so
the cron path and the HTTP path cannot diverge. `pg_cron` can call the SQL
function directly, which is how this project's existing `qai_*` jobs work.

## Vocabulary (pinned)

| Value | Meaning |
| --- | --- |
| `driver_assignments.status = 'offered'` | a live offer is counting down |
| `driver_assignments.status = 'expired'` | the sweep cleared an unanswered offer |
| `driver_assignments.status = 'declined'` | the driver turned the offer down (`decline_dispatch_offer`) |
| `driver_assignments.status = 'assigned'` | the driver accepted (`accept_dispatch_offer`) |
| `driver_assignments.offer_expires_at` | `created_at + timeout_seconds` while live, `NULL` once closed |
| `orders.status = 'ready_for_pickup'` | order is back in the driver queue |
| `notifications.data.event = 'dispatch_offer_expired'` | upsert key marker for the customer inbox row |

`driver_assignments.status` is unconstrained `text` in the remote DB, so no
status migration is needed. `orders.status` reuses the existing `OrderStatus`
vocabulary — no new order status was added.

"One driver can win" is enforced by the database, not by application code:
`driver_assignments_one_active_per_order_idx` is a unique partial index over
`order_id` for every non-terminal status, so a second concurrent accept fails
with a `unique_violation` instead of silently creating a second courier.

## Configuration

The timeout is a database setting, not an environment variable or a secret:

```sql
-- default 60, floor 1
alter database postgres set app.dispatch_offer_timeout_seconds = '90';
```

It is read by `public.dispatch_offer_timeout_seconds()`, which both
`create_dispatch_offer` and the sweep use, so every path agrees. The apps must
**not** carry their own copy: the driver screen derives its countdown from
`offer_expires_at` / `timeout_seconds` on the row, so the server owns the
deadline.

## How an order reaches a driver (auto-dispatch)

| Piece | Where |
| --- | --- |
| `dispatch_origin(order)` | `store_location` when the store has one, else the customer's `delivery_address` point |
| `dispatch_radius_ladder_m()` | 2/4/8/15/30/50 km, overridable with `app.dispatch_radius_ladder_m` |
| `dispatch_max_radius_m(store)` | `stores.delivery_radius_km` (default 25 km) caps the ladder |
| `dispatch_next_driver(order)` | Nearest eligible driver, offered through the already-verified `create_dispatch_offer` |
| `auto_dispatch_ready_orders()` | Every `ready_for_pickup` order with nothing live on it |
| `run_dispatch_tick()` | Expire lapsed offers, then re-offer — the single cron entry point |
| `trg_orders_auto_dispatch` | Fires the moment an order becomes `ready_for_pickup` |

Rules it enforces: only `ready_for_pickup` orders with no live assignment are
dispatched; only the nearest eligible driver is offered (online, not
soft-deleted, position seen in the last 15 minutes, not already carrying an
order); anyone who already has a row for that order — accepted, declined or
allowed to expire — is never offered it again; and the search never leaves the
store's own delivery radius. The trigger swallows its own errors with a
`RAISE WARNING`, so a dispatch problem can never block a store accepting an order.

Two limits worth knowing before tuning:

- **Drivers are ranked against the customer, not the store.** Only 2 of 16
  stores have `store_location`, and no order belongs to one of them, so today
  `dispatch_origin` falls back to the delivery address on every order. Geocoding
  the stores (or filling `store_location`) is the real fix.
- `delivery_polygon` exists as a column but **no store has one**, so the
  postgis permitted-area polygon plays no part. `delivery_radius_km` stands in
  for it.

The widening is driven by attempts (each offer leaves a row) plus waiting time,
so an order whose first radius finds nobody at all still escalates. Because
candidates are ranked nearest-first, an over-wide radius can only ever pick the
same nearest driver; the ladder decides when to give up, not who to choose.

## Deploy

The migration is already applied. What is left:

```bash
# 1. Deploy the HTTP wrapper (optional; cron can call the SQL function direct)
supabase functions deploy enforce-dispatch-offer-timeout \
  --project-ref lxsvydiyzeavdqbjxkpp

# 2. The dispatch loop is already scheduled as ONE tick that clears lapsed
#    offers and then re-offers the orders still waiting (pg_cron's finest
#    granularity is one minute). Verified running on 2026-10-11.
select cron.schedule(
  'queless-dispatch-tick',
  '* * * * *',
  $$select public.run_dispatch_tick()$$
);

# 3. Stop it again
select cron.unschedule('queless-dispatch-tick');
```

A 60s timeout with a 60s cadence can leave an offer live for up to ~120s before
it is cleared. If that is too loose, shorten the timeout rather than the cadence
(which cannot go below one minute).

If you would rather drive the sweep over HTTP from an external cron, POST the
function URL with `Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY` and never
inline that key in job SQL, which is readable by anyone with database access.

## Companion change — done

`supabase/functions/orders-status/index.ts` (in `queless-v1.0.1`; the canonical
state machine all three apps call) used to read the current assignment with an
unfiltered `.eq("order_id", orderId).maybeSingle()`, which errors once an order
has more than one assignment row — exactly the history time-boxed offers create,
because expired and declined rows stay behind as the audit trail.

Both single-row reads in that function now resolve the **live** assignment
through a shared `fetchLiveAssignment(orderId)` helper: it loads the order's
rows and picks the newest one whose status is not terminal, mirroring the
database's `driver_assignment_status_is_active()`. It deliberately does not use
`.in("status", ["offered", "assigned"])`, which would have locked out the legacy
mixed-case `Picked up` status already present in the table.

A workspace-wide search found no other unguarded single-row read of
`driver_assignments`.

Two more gaps that block a working dispatch loop, both in the driver app repo:

- **Confirm `driver_locations` is populated on device.** The publish path
exists (`publishLocation` upserts the table in
`queless_driver/lib/services/order_service.dart`), but the table is empty and
`nearby_eligible_drivers` requires a position seen in the last 15 minutes, so
today dispatch matches nobody at any radius. RLS is not the cause — the table
has `driver_upserts_own_location` for `authenticated`, and all eight columns the
app writes exist (checked 2026-10-11) — so the likeliest reading is that no
driver has published since the table was created. Note that the upsert is
wrapped in a `catch` that logs and continues, so a future failure there would
surface only as a "non-critical" debug warning.
- **The loop is closed in code now**: auto-dispatch calls
  `create_dispatch_offer`, and the driver app calls `accept_dispatch_offer` /
  `decline_dispatch_offer` with an offer countdown. What is still unproven is
  the last mile — no device has run that build, and no offer can reach one until
  `driver_locations` has rows.

## Smoke test

Run in the dashboard SQL editor unless stated otherwise. Replace the canary
`order_id` with a real order waiting for a driver, and `<driver_user_id>` with a
`drivers.user_id`.

```sql
-- 0. Canary
select id, status, order_number from public.orders
where status = 'ready_for_pickup' order by created_at desc limit 5;

-- 1. Create the offer through the real entry point, with a short timeout.
select * from public.create_dispatch_offer('<order_id>', '<driver_user_id>', 30);

-- 2. Expect: one 'offered' row with offer_expires_at set and the timeout recorded.
select id, status, offer_expires_at, timeout_seconds
from public.driver_assignments where order_id = '<order_id>';

-- 3. Run the sweep once, as the service role.
select * from public.enforce_dispatch_offer_timeout();

-- 4. Expect while fresh: offers_stamped = 0/1, offers_expired = 0.
--    After the 30s have lapsed: offers_expired = 1, orders_requeued = 1,
--    notifications_sent = 1.

-- 5. Expect the assignment cleared and the order back in the queue.
select id, status, offer_expires_at, timeout_seconds
from public.driver_assignments where order_id = '<order_id>';
-- status = 'expired', offer_expires_at is null, timeout_seconds is null
select status, tracking_updates from public.orders where id = '<order_id>';
-- status = 'ready_for_pickup'; tracking_updates ends with {"status":"ready_for_pickup", ...}

-- 6. Expect exactly one customer notification for this order.
select id, title, status, data->>'event' as event
from public.notifications
where order_id = '<order_id>' and data->>'event' = 'dispatch_offer_expired';

-- 7. Idempotency: run the sweep again.
--    Expect offers_expired = 0 and still exactly one notification row.
--    The cleared row is no longer 'offered', so it is not picked up at all.

-- 8. Concurrency: two offers on one order must not both survive.
select * from public.create_dispatch_offer('<order_id>', '<driver_user_id>', 30);
-- a second call for the same order raises 23505 "already has a live assignment";
-- two simultaneous accepts from different drivers leave exactly one live row
-- (the loser gets unique_violation on driver_assignments_one_active_per_order_idx).
```

Also check, before scheduling:

- **Auth** — the same POST function call **without** the `Authorization` header
  returns `401 {"error":"Service-role token required."}`.
- **Method** — a `DELETE` returns `405`.
- **Legacy rows** — an assignment that never had an offer (both offer columns
  `NULL`) is untouched by both passes.

## Verified in the live database on 2026-10-11

The whole flow was exercised against project `lxsvydiyzeavdqbjxkpp` inside a
transaction that was then rolled back, so nothing persisted. Confirmed:

| Check | Result |
| --- | --- |
| `create_dispatch_offer` + `accept_dispatch_offer` | assignment → `assigned`, order → `driver_assigned`, timeline entry appended |
| Order state machine guard on accept | an offer on a still-`preparing` order is refused with `22023` |
| Wrong driver accepting/declining | refused with `42501` |
| `decline_dispatch_offer` | assignment → `declined`, order stays queued, the next offer succeeds |
| Sweep after expiry | `offers_expired = 1`, `orders_requeued = 1`, `notifications_sent = 1`; assignment → `expired`, order → `ready_for_pickup`, timeline entry appended |
| Sweep re-run | `offers_expired = 0`, still exactly one notification (idempotent) |
| Re-offer after expiry | succeeds (the partial index frees the order) |
| Live duplicates per order | 0 after every step |
| Leakage | orders 74 → 74, assignments 14 → 14, no `offered`/`expired`/`declined` leftovers, no test orders |
| Catalog | all 7 dispatch functions + 8 auto-dispatch functions, both indexes, realtime publication, `trg_orders_auto_dispatch`, and `queless-dispatch-tick` scheduled alongside the 5 pre-existing cron jobs |
| Auto-dispatch | trigger offered the nearest of two seeded drivers (554 m), a decline excluded that driver and the retry reached the other, radius capped by the store's 5 km |
| Scheduled tick | observed succeeding twice after scheduling, `1 row` returned each time |

## Rollback

The sweep is additive and reversible:

```sql
-- Stop the sweep first (unschedule the cron job), then:
update public.driver_assignments
   set status = 'assigned', offer_expires_at = null, timeout_seconds = null
 where status = 'expired';
-- then run the rollback block at the bottom of the migration.
```

## Verification status

Checked locally on 2026-10-11, in this repo:

- `flutter analyze` — clean.
- `flutter test` — 9/9 pass
  ([`test/driver_assignment_offer_test.dart`](../test/driver_assignment_offer_test.dart)),
  covering legacy rows, the round trip, live offers, the expiry instant, and
  both cleared-offer statuses.
- `node --check` parses the rewritten sweep wrapper (exit 0) and it no longer
  imports the deleted `dispatchOffer.ts`.

**Not** checked here, and required before calling Phase B live:

- No `deno` on this machine, so `deno check` / `deno lint` and a local
  `supabase functions serve` run did not happen. The wrapper is parse-verified,
  **not runtime-verified**, and is not deployed.
- The migrations are applied, and the dispatch tick is scheduled and observed
  succeeding. The loop is nonetheless unproven end to end: no driver has
  published a position, so `nearby_eligible_drivers` matches nobody and no offer
  can yet be created for a real order.
- The smoke test above has not been run as written. The companion
  `orders-status` change is implemented and parse-checked, but not deployed.

## Still outside this repo

- **Driver app** (`queless_driver`): publish positions to `driver_locations`,
  accept/decline through the RPCs, show `offerExpiresAt` counting down via
  `DriverAssignmentModel.offerRemaining`, disable accept/decline once
  `canRespondToOffer` is false, and refetch when the sweep closed the offer
  underneath it.
- **Customer app** (`queless-v1.0.1`): render the appended `tracking_updates`
  entry; no dispatch-offer action by design.
