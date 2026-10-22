# Phase A — Post-Deployment Settlement Parity Check

## What was deployed

Two Supabase Edge functions were deployed from the `payments-secure` branch
snapshot to `queless-v1.0.1` (project `lxsvydiyzeavdqbjxkpp.supabase.co`):

1. `paystack-settlements` — `verify_jwt = true`, parity with the on-disk
   `supabase/functions/paystack-settlements/index.ts`.
2. `initialize-paystack-split` — hardened server-side settlement version,
   parity with the on-disk
   `supabase/functions/initialize-paystack-split/index.ts`.

Both carry `config.toml` + `deno.json` matching the existing paystack function
convention (`paystack-callback` / `webhook`).

## What the parity check proves

The script at [`scripts/phase_a_parity_check.mjs`](scripts/phase_a_parity_check.mjs)
runs **against the live DB** and proves three things simultaneously:

- **SQL ↔ Dart parity:** the server-side `compute_order_shares(p_order_id text)`
  RPC function returns the same `store_share` and `queless_share` as a clean
  JS reimplementation of the exact paystack-split formula.
- **Formula integrity:** the recomputed Queless share keeps the platform margin
  **+ service fee**, not the delivery fee (delivery fee scales with distance and
  is not retained by the platform).
- **Stored-data consistency:** the existing `orders.store_share` /
  `orders.queless_share` columns agree with both recomputations on delivered
  orders.

This is the authoritative check because it does **not** trust the client
metadata that the old `initialize-paystack-split` trusted. The new version
recomputes `quelessShare` from `order.delivery_fee` server-side, and the parity
script independently recomputes the same formula and compares it to both the RPC
result and the stored columns.

## What it does NOT need

- No Paystack secret key (the script only reads Supabase order rows and calls
  the RPC — it never hits Paystack).
- No Dart runtime (it is a plain Node script against the DB).

## What it DOES need

Only the **Supabase service-role key**, because the SQL function and order rows
are server-side. The script reads the key from **either**:

- env `SU_SERVICE_KEY`, or
- the file `scripts/.supabase_service_key` (one line, no quotes).

The key is **never** read from or printed to chat. Put it in the file or env and
run the script.

## Run it

```bash
# Option 1 — env:
SU_SERVICE_KEY="<service-role-key>" node scripts/phase_a_parity_check.mjs

# Option 2 — file (create it once, then run):
#   Put the key on a single line in scripts/.supabase_service_key (no quotes).
node scripts/phase_a_parity_check.mjs
```

The script is ES module (`type: "module"`), depends on `@supabase/supabase-js`,
and expects that package under `scripts/node_modules/`. `scripts/package.json`
is present for that.

## Expected outcome

On a healthy deployment the script prints:

```
SQL function compute_order_shares callable: YES
Checking N orders ...
Checked N orders with complete data.
Sample recomputes (id → js vs sql):
  <order_id>: store_share js=X sql=X | queless_share js=Y sql=Y
    quelessKeepsMarginAndFee=true quelessNotJustDeliveryFee=true
Mismatches (js vs sql vs stored): 0
Queless keeps service fee + margin logic: PASS

=== Phase A settlement parity: VERIFIED ===
```

and exits 0.

## Meaning of a failure

If it exits non-zero:

- **function not callable** → the RPC migration did not apply; re-run
  `lib/supabase/migrations/20260725_add_paystack_split_settlement.sql` against
  the project DB.
- **mismatches** → the deployed edge function and/or the SQL function disagree
  with the canonical formula. Compare the sample rows in the output against the
  formula in [`scripts/phase_a_parity_check.mjs`](scripts/phase_a_parity_check.mjs)
  and the on-disk edge function source.

## Carry-forward note (Phase B)

This is a Phase A check. Phase B is the dispatch offer timeout in seconds, which
is a separate concern and is not covered by this parity script.
