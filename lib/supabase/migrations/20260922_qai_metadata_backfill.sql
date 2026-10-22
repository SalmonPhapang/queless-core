-- 20260922_qai_metadata_backfill.sql
--
-- Q AI Phase 4 — Product & Store AI metadata, derived from the existing
-- catalog (queless_ai_roadmap.md §8).
--
-- Design:
--   * One row-level derivation function per table
--     (qai_upsert_product_metadata / qai_upsert_store_metadata). The set-based
--     backfill loops over them, and AFTER INSERT/UPDATE triggers on the
--     catalog call the same functions — one derivation implementation, ever.
--   * The backfill OWNS the derived columns (meal_types, flavour_tags,
--     spicy_level, dietary booleans, ingredient/cuisine tags, searchable_text).
--     Re-running is idempotent.
--   * Curated columns (ai_description, embedding) are NEVER touched by these
--     functions — merchants/LLM pipelines can write them without fear.
--   * Honest unknowns: vegetarian/vegan stay NULL without positive evidence;
--     halal_status only becomes 'halal' when the menu text says so (never
--     'certified_halal' by inference).
--
-- Catalog notes this was calibrated against (2026-09-22):
--   271 products (17 alcohol, rest kasi food), 16 stores, tags array empty
--   on every product, product_type casing inconsistent ('Food'/'food').

BEGIN;

-- ============================================================
-- Product metadata derivation (one row)
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_upsert_product_metadata(p_product_id uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  r public.products%ROWTYPE;
  v_text text;
  v_is_alcohol boolean;
  v_meal_types text[];
  v_cuisine_tags text[];
  v_ingredient_tags text[];
  v_flavour text[];
  v_spicy smallint;
  v_veggie boolean;
  v_vegan boolean;
  v_halal text;
BEGIN
  SELECT * INTO r FROM public.products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_is_alcohol := lower(COALESCE(r.product_type, '')) = 'alcohol';

  -- name + brand + category + description, one searchable blob
  v_text := lower(concat_ws(' ',
    r.name, r.brand, r.category, r.description,
    array_to_string(COALESCE(r.tags, '{}'), ' ')));

  -- ---- meal types ----------------------------------------------------------
  IF v_is_alcohol THEN
    v_meal_types := ARRAY['alcohol'];
  ELSE
    v_meal_types := ARRAY[]::text[];
    IF r.category ILIKE ANY (ARRAY['drinks', 'beverages', 'cooldrinks', 'juice', 'juices', 'water', 'energy drinks', 'soda'])
       OR v_text ~ '(cooldrink|soft drink|juice|energy drink|still water|sparkling water)' THEN
      v_meal_types := v_meal_types || 'beverage'::text;
    END IF;
    IF r.category ILIKE ANY (ARRAY['desserts', 'dessert'])
       OR v_text ~ '(dessert|ice cream|sundae|cake|milkshake|sweet treat|chocolate|caramel)' THEN
      v_meal_types := v_meal_types || 'dessert'::text;
    END IF;
    IF r.category ILIKE ANY (ARRAY['sides', 'side', 'chips', 'fries', 'salads'])
       OR v_text ~ '(chips|fries|slap chips|side salad|small salad)' THEN
      v_meal_types := v_meal_types || 'side'::text;
    END IF;
    IF r.category ILIKE ANY (ARRAY['breakfast', 'eggs'])
       OR v_text ~ '(breakfast|fried egg|scrambled egg)' THEN
      v_meal_types := v_meal_types || 'breakfast'::text;
    END IF;
    -- mains: everything food that isn't a drink/dessert-only item
    IF NOT ('beverage' = ANY (v_meal_types) AND array_length(v_meal_types, 1) = 1) THEN
      v_meal_types := v_meal_types || 'main'::text;
    END IF;
    IF array_length(v_meal_types, 1) IS NULL THEN
      v_meal_types := ARRAY['main'];
    END IF;
  END IF;

  -- ---- flavour tags --------------------------------------------------------
  v_flavour := ARRAY[]::text[];
  IF v_text ~ '(spicy|hot sauce|chilli|chili|peri peri|periperi|jalap|curry|atachar)' THEN
    v_flavour := v_flavour || 'spicy'::text;
  END IF;
  IF v_text ~ '(sweet|caramel|choc|syrup|honey|dessert|milkshake)' THEN
    v_flavour := v_flavour || 'sweet'::text;
  END IF;
  IF v_text ~ '(cheese|cheesy|grilled|braaied|bbq|braai|bacon|garlic|butter|savoury|savory)' THEN
    v_flavour := v_flavour || 'savoury'::text;
  END IF;

  -- ---- spice level (food only) --------------------------------------------
  IF NOT v_is_alcohol THEN
    v_spicy :=
      CASE
        WHEN v_text ~ '(extra hot|extra spicy|very hot|hottest|fire)' THEN 3
        WHEN v_text ~ '(spicy|hot|chilli|chili|peri peri|periperi|jalap)' THEN 2
        WHEN v_text ~ '(mild|sweet chilli|medium)' THEN 1
        ELSE 0
      END;
  ELSE
    v_spicy := NULL;
  END IF;

  -- ---- dietary (evidence-based, honest NULLs) ------------------------------
  IF v_is_alcohol THEN
    v_veggie := NULL; v_vegan := NULL;
  ELSE
    v_veggie := NULL;
    v_vegan  := NULL;
    IF v_text ~ '(veggie|vegetarian)' THEN v_veggie := true; END IF;
    IF v_text ~ 'vegan' THEN v_vegan := true; v_veggie := true; END IF;
    IF v_text ~ '(chicken|beef|pork|bacon|wors|mince|rib|polony|russian|vienna|egg|cheese|fish)' THEN
      v_veggie := false;
    END IF;
  END IF;

  v_halal := CASE WHEN v_text ~ '(halal|halaal)' THEN 'halal' ELSE 'unknown' END;

  -- ---- ingredient tags (light keyword extraction) ---------------------------
  v_ingredient_tags := ARRAY[]::text[];
  IF v_text ~ '(chicken)' THEN v_ingredient_tags := v_ingredient_tags || 'chicken'::text; END IF;
  IF v_text ~ 'beef' THEN v_ingredient_tags := v_ingredient_tags || 'beef'::text; END IF;
  IF v_text ~ 'pork' THEN v_ingredient_tags := v_ingredient_tags || 'pork'::text; END IF;
  IF v_text ~ '(boerewors|wors)' THEN v_ingredient_tags := v_ingredient_tags || 'boerewors'::text; END IF;
  IF v_text ~ 'mince' THEN v_ingredient_tags := v_ingredient_tags || 'mince'::text; END IF;
  IF v_text ~ '(rib|ribs)' THEN v_ingredient_tags := v_ingredient_tags || 'ribs'::text; END IF;
  IF v_text ~ '(cheese|cheesy|cheddar)' THEN v_ingredient_tags := v_ingredient_tags || 'cheese'::text; END IF;
  IF v_text ~ '(chips|fries)' THEN v_ingredient_tags := v_ingredient_tags || 'chips'::text; END IF;
  IF v_text ~ 'bacon' THEN v_ingredient_tags := v_ingredient_tags || 'bacon'::text; END IF;
  IF v_text ~ '(egg|eggs)' THEN v_ingredient_tags := v_ingredient_tags || 'egg'::text; END IF;
  IF v_text ~ '(lettuce|salad)' THEN v_ingredient_tags := v_ingredient_tags || 'lettuce'::text; END IF;
  IF v_text ~ 'tomato' THEN v_ingredient_tags := v_ingredient_tags || 'tomato'::text; END IF;
  IF v_text ~ 'onion' THEN v_ingredient_tags := v_ingredient_tags || 'onion'::text; END IF;
  IF v_text ~ '(gherkin|pickle)' THEN v_ingredient_tags := v_ingredient_tags || 'gherkin'::text; END IF;
  IF v_text ~ 'mushroom' THEN v_ingredient_tags := v_ingredient_tags || 'mushroom'::text; END IF;
  IF v_text ~ 'avocado' THEN v_ingredient_tags := v_ingredient_tags || 'avocado'::text; END IF;
  IF v_text ~ '(kota|bread|roll|bun)' THEN v_ingredient_tags := v_ingredient_tags || 'bread'::text; END IF;
  IF v_text ~ '(russian|vienna|polony|griller|sausage)' THEN v_ingredient_tags := v_ingredient_tags || 'processed meat'::text; END IF;

  -- ---- cuisine tags: inherit the store's category ---------------------------
  SELECT ARRAY_REMOVE(ARRAY[LOWER(TRIM(s.category))], '')
    INTO v_cuisine_tags
  FROM public.stores s
  WHERE s.id = r.store_id;

  INSERT INTO public.product_ai_metadata
    (product_id, cuisine_tags, dietary_tags, ingredient_tags, meal_types,
     flavour_tags, halal_status, vegetarian, vegan, spicy_level, searchable_text)
  VALUES
    (p_product_id,
     COALESCE(v_cuisine_tags, '{}'),
     ARRAY[]::text[],
     COALESCE(v_ingredient_tags, '{}'),
     COALESCE(v_meal_types, '{}'),
     COALESCE(v_flavour, '{}'),
     v_halal,
     v_veggie,
     v_vegan,
     v_spicy,
     v_text)
  ON CONFLICT (product_id) DO UPDATE
    SET cuisine_tags    = EXCLUDED.cuisine_tags,
        dietary_tags    = EXCLUDED.dietary_tags,
        ingredient_tags = EXCLUDED.ingredient_tags,
        meal_types      = EXCLUDED.meal_types,
        flavour_tags    = EXCLUDED.flavour_tags,
        halal_status    = EXCLUDED.halal_status,
        vegetarian      = EXCLUDED.vegetarian,
        vegan           = EXCLUDED.vegan,
        spicy_level     = EXCLUDED.spicy_level,
        searchable_text = EXCLUDED.searchable_text;
END $fn$;

-- ============================================================
-- Store metadata derivation (one row)
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_upsert_store_metadata(p_store_id uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  r public.stores%ROWTYPE;
  v_text text;
  v_cuisine text[];
  v_speciality text[];
  v_dietary text[];
BEGIN
  SELECT * INTO r FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_text := lower(concat_ws(' ',
    r.name, r.category, r.description,
    array_to_string(COALESCE(r.cuisine_types, '{}'), ' '),
    array_to_string(COALESCE(r.tags, '{}'), ' ')));

  v_cuisine := ARRAY_REMOVE(ARRAY[LOWER(TRIM(r.category))], '');
  v_cuisine := v_cuisine
    || (SELECT COALESCE(array_agg(LOWER(TRIM(c))), '{}')
        FROM unnest(COALESCE(r.cuisine_types, '{}')) AS c
        WHERE TRIM(c) <> '');

  v_speciality := ARRAY[]::text[];
  IF v_text ~ '(bottle store|liquor|beer|wine|spirits)' THEN
    v_speciality := v_speciality || 'liquor'::text;
  END IF;
  IF v_text ~ 'kota' THEN v_speciality := v_speciality || 'kota'::text; END IF;
  IF v_text ~ '(braai|bbq|shisanyama|chesa)' THEN v_speciality := v_speciality || 'braai'::text; END IF;
  IF v_text ~ 'burger' THEN v_speciality := v_speciality || 'burgers'::text; END IF;
  IF v_text ~ 'pizza' THEN v_speciality := v_speciality || 'pizza'::text; END IF;
  IF v_text ~ 'chicken' THEN v_speciality := v_speciality || 'chicken'::text; END IF;
  IF v_text ~ '(pap|wors|kasi|township)' THEN v_speciality := v_speciality || 'kasi classics'::text; END IF;
  IF v_text ~ '(fast food|take away|takeaway|quick)' THEN v_speciality := v_speciality || 'fast food'::text; END IF;

  v_dietary := ARRAY[]::text[];
  IF v_text ~ '(halal|halaal)' THEN v_dietary := v_dietary || 'halal'::text; END IF;
  IF v_text ~ '(vegetarian|veggie|vegan)' THEN v_dietary := v_dietary || 'vegetarian options'::text; END IF;

  INSERT INTO public.store_ai_metadata
    (store_id, cuisine_tags, dietary_tags, speciality_tags, searchable_text)
  VALUES
    (p_store_id,
     COALESCE(v_cuisine, '{}'),
     COALESCE(v_dietary, '{}'),
     COALESCE(v_speciality, '{}'),
     v_text)
  ON CONFLICT (store_id) DO UPDATE
    SET cuisine_tags    = EXCLUDED.cuisine_tags,
        dietary_tags    = EXCLUDED.dietary_tags,
        speciality_tags = EXCLUDED.speciality_tags,
        searchable_text = EXCLUDED.searchable_text;
END $fn$;

-- ============================================================
-- Backfill entry points (return processed row counts)
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_backfill_product_metadata()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*) INTO v_count FROM public.products;
  PERFORM public.qai_upsert_product_metadata(p.id) FROM public.products p;
  RETURN v_count;
END $fn$;

CREATE OR REPLACE FUNCTION public.qai_backfill_store_metadata()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*) INTO v_count FROM public.stores;
  PERFORM public.qai_upsert_store_metadata(s.id) FROM public.stores s;
  RETURN v_count;
END $fn$;

REVOKE ALL ON FUNCTION public.qai_backfill_product_metadata() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.qai_backfill_store_metadata() FROM PUBLIC, anon;

-- ============================================================
-- Sync triggers: catalog edits keep metadata fresh via the same functions.
-- SECURITY DEFINER + guarded: a metadata hiccup must never fail a catalog
-- write (the alerts-incident rule applies to merchant saves too).
-- ============================================================

CREATE OR REPLACE FUNCTION public.qai_sync_product_meta_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  PERFORM public.qai_upsert_product_metadata(NEW.id);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'qai product metadata sync failed for %: %', NEW.id, SQLERRM;
  RETURN NEW;
END $fn$;

CREATE OR REPLACE FUNCTION public.qai_sync_store_meta_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  PERFORM public.qai_upsert_store_metadata(NEW.id);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'qai store metadata sync failed for %: %', NEW.id, SQLERRM;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_qai_product_meta_sync ON public.products;
CREATE TRIGGER trg_qai_product_meta_sync
  AFTER INSERT OR UPDATE OF name, brand, category, description, tags, product_type, store_id
  ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.qai_sync_product_meta_trigger();

DROP TRIGGER IF EXISTS trg_qai_store_meta_sync ON public.stores;
CREATE TRIGGER trg_qai_store_meta_sync
  AFTER INSERT OR UPDATE OF name, category, description, cuisine_types, tags
  ON public.stores
  FOR EACH ROW EXECUTE FUNCTION public.qai_sync_store_meta_trigger();

COMMIT;

-- ============================================================
-- IMPORTANT (2026-09-22): inside plpgsql, `text[] || 'literal'` resolves to
-- array-array concatenation and fails with "malformed array literal". Every
-- append in this file therefore casts the element: `|| 'tag'::text`.
-- Keep that convention when adding new tag rules.
-- ============================================================
