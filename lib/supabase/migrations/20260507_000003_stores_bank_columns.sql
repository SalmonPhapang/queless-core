-- =============================================
-- Migration: Add bank detail columns to stores table
-- Created: 2026-05-07
-- Purpose: Support Paystack payouts by storing bank account details
--          as individual columns (not JSONB) for easier querying
--          and storing the paystack_recipient_code for transfers
-- =============================================

-- Add bank detail columns to stores table
ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS bank_name TEXT,
  ADD COLUMN IF NOT EXISTS bank_code TEXT,
  ADD COLUMN IF NOT EXISTS account_number TEXT,
  ADD COLUMN IF NOT EXISTS account_name TEXT,
  ADD COLUMN IF NOT EXISTS paystack_recipient_code TEXT;

-- Add index on paystack_recipient_code for faster Paystack lookups
CREATE INDEX IF NOT EXISTS idx_stores_paystack_recipient_code ON public.stores(paystack_recipient_code);
