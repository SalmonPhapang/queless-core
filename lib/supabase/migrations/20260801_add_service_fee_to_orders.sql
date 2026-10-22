DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_name = 'orders'
      AND column_name = 'service_fee'
  ) THEN
    ALTER TABLE orders ADD COLUMN service_fee DOUBLE PRECISION NOT NULL DEFAULT 7.0;
  END IF;
END $$;
