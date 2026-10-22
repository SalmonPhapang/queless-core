-- =============================================
-- Migration: Rename subaccount_code to paystack_recipient_code
-- Created: 2026-05-21
-- Purpose: Better naming for Paystack transfer recipients
-- =============================================

-- Rename the column in stores table
ALTER TABLE public.stores 
RENAME COLUMN subaccount_code TO paystack_recipient_code;

-- Rename the index for consistency
ALTER INDEX IF EXISTS idx_stores_subaccount_code RENAME TO idx_stores_paystack_recipient_code;
