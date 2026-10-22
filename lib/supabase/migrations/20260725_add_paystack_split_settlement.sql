-- ===========================================================================
-- QUELESS — Paystack split settlement columns
--
-- Adds the columns the paystack settlement split expects on `orders`, plus a
-- backfill for any existing rows that predate the migration.
--
-- Columns:
--   base_subtotal         — the pre-markup food/subtotal value from the store.
--   base_price_adjustment — any store-side price adjustment (markdowns, etc.).
--   store_share           — what the store actually receives after discounts.
--   queless_share         — what Queless keeps (platform margin + service fee).
--
-- The OLD (wrong) split trusted client-supplied metadata and effectively gave
-- Queless:  total - store_share - delivery_fee   (lost the margin).
--
-- The NEW (correct) split is computed server-side in
-- compute_order_shares(p_order_id text) and follows the paystack split rules:
--   storeShare = base_subtotal - vendor_discount_absorbed   (>= 0)
--   quelessShare = total - storeShare                      (keeps margin + fee)
--
-- Backfill logic:
--   - base_subtotal / base_price_adjustment → 0 where absent.
--   - store_share     → base_subtotal where absent (store gets full subtotal).
--   - queless_share   → max(total - base_subtotal, 0) where absent
--                       (Queless keeps the markup portion, nothing from subtotal).
-- ===========================================================================

alter table if exists public.stores
  add column if not exists subaccount_code text;

alter table if exists public.orders
  add column if not exists base_subtotal numeric(12,2) default 0,
  add column if not exists base_price_adjustment numeric(12,2) default 0,
  add column if not exists store_share numeric(12,2) default 0,
  add column if not exists queless_share numeric(12,2) default 0;

update public.orders
set
  base_subtotal = coalesce(base_subtotal, 0),
  base_price_adjustment = coalesce(base_price_adjustment, 0),
  store_share = coalesce(store_share, coalesce(base_subtotal, 0)),
  queless_share = coalesce(
    queless_share,
    greatest(coalesce(total, 0) - coalesce(base_subtotal, 0), 0)
  )
where
  base_subtotal is null
  or base_price_adjustment is null
  or store_share is null
  or queless_share is null;
