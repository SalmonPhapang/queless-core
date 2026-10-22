-- Migration: Add owner_id to stores and create notifications table
-- Created: 2026-02-19 13:20:52

-- Add owner_id column to stores table
ALTER TABLE stores ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES auth.users(id) ON DELETE CASCADE;

-- Create index on owner_id for faster queries
CREATE INDEX IF NOT EXISTS idx_stores_owner_id ON stores(owner_id);

-- Update existing stores to have an owner (set to first user for now)
-- Note: In production, you should manually assign proper owners
UPDATE stores 
SET owner_id = (SELECT id FROM auth.users LIMIT 1)
WHERE owner_id IS NULL;

-- Create notifications table
CREATE TABLE IF NOT EXISTS notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  store_id UUID REFERENCES stores(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  type TEXT NOT NULL,
  data JSONB,
  is_read BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create indexes for notifications
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_store_id ON notifications(store_id);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON notifications(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_is_read ON notifications(is_read);

-- Add fcm_token column to users table for push notifications
ALTER TABLE users ADD COLUMN IF NOT EXISTS fcm_token TEXT;

-- Enable Row Level Security on notifications table
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- Create RLS policies for notifications
CREATE POLICY "Users can view their own notifications" ON notifications
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own notifications" ON notifications
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own notifications" ON notifications
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own notifications" ON notifications
  FOR DELETE USING (auth.uid() = user_id);

-- Update stores policies to allow owners to manage their stores
DROP POLICY IF EXISTS "Authenticated users can perform all operations on stores" ON stores;

CREATE POLICY "Anyone can view stores" ON stores
  FOR SELECT USING (true);

CREATE POLICY "Store owners can update their stores" ON stores
  FOR UPDATE USING (auth.uid() = owner_id);

CREATE POLICY "Authenticated users can create stores" ON stores
  FOR INSERT WITH CHECK (auth.uid() = owner_id);

-- Update products policies to allow store owners to manage their products
DROP POLICY IF EXISTS "Authenticated users can perform all operations on products" ON products;

CREATE POLICY "Anyone can view products" ON products
  FOR SELECT USING (true);

CREATE POLICY "Store owners can manage their products" ON products
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM stores 
      WHERE stores.id = products.store_id 
      AND stores.owner_id = auth.uid()
    )
  );
