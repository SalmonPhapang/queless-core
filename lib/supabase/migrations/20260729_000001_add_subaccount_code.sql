-- =============================================
-- Migration: Add subaccount_code to stores table
-- Created: 2026-07-29
-- Purpose:
--   Stores the Paystack subaccount code (e.g. ACCT_xxxxx) used for
--   payment splitting in the customer front-end app. This is separate
--   from paystack_recipient_code (transfer recipient for payouts).
--
--   The subaccount_code allows us to query Paystack's Settlement API
--   to see which payments have been settled to the store's account.
-- =============================================

ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS subaccount_code TEXT;

-- Add index for faster lookups when querying Paystack
CREATE INDEX IF NOT EXISTS idx_stores_subaccount_code ON public.stores(subaccount_code);
