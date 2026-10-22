-- =============================================
-- FIX NEARBY STORES RPC TO INCLUDE DISTANCE
-- =============================================

CREATE OR REPLACE FUNCTION nearby_stores(
  lat double precision,
  long double precision,
  radius_meters double precision DEFAULT 5000
)
RETURNS TABLE (
  id uuid,
  name text,
  description text,
  image_url text,
  category text,
  cuisine_types text[],
  rating numeric(3,2),
  total_reviews integer,
  delivery_time_min integer,
  delivery_time_max integer,
  delivery_fee numeric(10,2),
  minimum_order numeric(10,2),
  is_open boolean,
  operating_hours jsonb,
  address text,
  phone text,
  tags text[],
  created_at timestamptz,
  updated_at timestamptz,
  owner_id uuid,
  is_approved boolean,
  location text,
  bank_name text,
  bank_code text,
  account_number text,
  account_name text,
  paystack_recipient_code text,
  is_alcohol boolean,
  dist_meters double precision
)
LANGUAGE sql
AS $$
  SELECT 
    s.id,
    s.name,
    s.description,
    s.image_url,
    s.category,
    s.cuisine_types,
    s.rating,
    s.total_reviews,
    s.delivery_time_min,
    s.delivery_time_max,
    s.delivery_fee,
    s.minimum_order,
    s.is_open,
    s.operating_hours,
    s.address,
    s.phone,
    s.tags,
    s.created_at,
    s.updated_at,
    s.owner_id,
    s.is_approved,
    s.location,
    s.bank_name,
    s.bank_code,
    s.account_number,
    s.account_name,
    s.paystack_recipient_code,
    s.is_alcohol,
    CASE 
      WHEN s.location = '' THEN NULL
      ELSE ST_Distance(
        ST_SetSRID(ST_MakePoint(
          split_part(s.location, ',', 2)::double precision, 
          split_part(s.location, ',', 1)::double precision
        ), 4326)::geography,
        ST_SetSRID(ST_MakePoint(long, lat), 4326)::geography
      )
    END AS dist_meters
  FROM public.stores s
  WHERE 
    CASE 
      WHEN s.location = '' THEN false
      ELSE ST_DWithin(
        ST_SetSRID(ST_MakePoint(
          split_part(s.location, ',', 2)::double precision, 
          split_part(s.location, ',', 1)::double precision
        ), 4326)::geography,
        ST_SetSRID(ST_MakePoint(long, lat), 4326)::geography,
        radius_meters
      )
    END
  ORDER BY 
    CASE 
      WHEN s.location = '' THEN NULL
      ELSE ST_SetSRID(ST_MakePoint(
          split_part(s.location, ',', 2)::double precision, 
          split_part(s.location, ',', 1)::double precision
        ), 4326)::geography <-> ST_SetSRID(ST_MakePoint(long, lat), 4326)::geography
    END;
$$;
