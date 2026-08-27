-- FUNCTION: public.get_new_products_by_filters(integer, text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], timestamp without time zone)

-- DROP FUNCTION IF EXISTS public.get_new_products_by_filters(integer, text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], timestamp without time zone);

CREATE OR REPLACE FUNCTION public.get_new_products_by_filters(
	p_event_id integer,
	p_skus text[] DEFAULT NULL::text[],
	p_part_numbers text[] DEFAULT NULL::text[],
	p_supplier_ids text[] DEFAULT NULL::text[],
	p_not_supplier_ids text[] DEFAULT NULL::text[],
	p_supplier_names text[] DEFAULT NULL::text[],
	p_brands text[] DEFAULT NULL::text[],
	p_not_brands text[] DEFAULT NULL::text[],
	p_ic1 text[] DEFAULT NULL::text[],
	p_not_ic1 text[] DEFAULT NULL::text[],
	p_ic2 text[] DEFAULT NULL::text[],
	p_not_ic2 text[] DEFAULT NULL::text[],
	p_ic3 text[] DEFAULT NULL::text[],
	p_not_ic3 text[] DEFAULT NULL::text[],
	p_ic4 text[] DEFAULT NULL::text[],
	p_not_ic4 text[] DEFAULT NULL::text[],
	p_searchedat timestamp without time zone DEFAULT NULL::timestamp without time zone)
    RETURNS TABLE(sku text, part_no text, country text, item_class1 text, showroom_indicator text, clearance text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    v_sql TEXT;
    v_where TEXT := ' WHERE UPPER(country) = UPPER((SELECT country FROM "tEvent" WHERE "eventId" = ' || p_event_id || ')) ';
    v_searched_at_date_literal TEXT;
    v_isnew_cond TEXT;   -- boolean condition as TEXT
BEGIN
 
       v_searched_at_date_literal := CASE
        WHEN p_searchedAt IS NULL THEN 'NULL'
        ELSE quote_literal(p_searchedAt::timestamp)    -- e.g. '2025-11-29'
    END;
    v_isnew_cond := 
        'f."createdAt" IS NOT NULL'
        || ' AND f."createdAt"::timestamp > ' || v_searched_at_date_literal;

    IF p_skus IS NOT NULL AND array_length(p_skus, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(ARRAY(SELECT format('"sku" ILIKE %L', s || '%') FROM unnest(p_skus) s), ' OR ')
            || ') ';
    END IF;
 
    IF p_part_numbers IS NOT NULL AND array_length(p_part_numbers, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(ARRAY(SELECT format('"partNo" ILIKE %L', s || '%') FROM unnest(p_part_numbers) s), ' OR ')
            || ') ';
    END IF;
 
    IF p_supplier_ids IS NOT NULL AND array_length(p_supplier_ids, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(ARRAY(SELECT format('"supplierId" ILIKE %L', s || '%') FROM unnest(p_supplier_ids) s), ' OR ')
            || ') ';
    END IF;
 
    IF p_not_supplier_ids IS NOT NULL AND array_length(p_not_supplier_ids, 1) > 0 THEN
        v_where := v_where || ' AND NOT (' ||
            array_to_string(ARRAY(SELECT format('"supplierId" ILIKE %L', s || '%') FROM unnest(p_not_supplier_ids) s), ' OR ')
            || ') ';
    END IF;
 
    -- Same pattern for brand and item class filters:
    IF p_brands IS NOT NULL AND array_length(p_brands, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(ARRAY(SELECT format('"brand" ILIKE %L',  s ) FROM unnest(p_brands) s), ' OR ')
            || ') ';
    END IF;
 
    IF p_not_brands IS NOT NULL AND array_length(p_not_brands, 1) > 0 THEN
        v_where := v_where || ' AND NOT (' ||
            array_to_string(ARRAY(SELECT format('"brand" ILIKE %L',  s ) FROM unnest(p_not_brands) s), ' OR ')
            || ') ';
    END IF;
 
     IF p_ic1 IS NOT NULL AND array_length(p_ic1, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(
                ARRAY(SELECT format('"itemClass1" ILIKE %L', s) FROM unnest(p_ic1) s),
                ' OR '
            ) || ') ';
    END IF;
 
    IF p_not_ic1 IS NOT NULL AND array_length(p_not_ic1, 1) > 0 THEN
        v_where := v_where || ' AND NOT (' ||
            array_to_string(
                ARRAY(SELECT format('"itemClass1" ILIKE %L', s) FROM unnest(p_not_ic1) s),
                ' OR '
            ) || ') ';
    END IF;
 
    --------------------------------------------------------
    -- Item Class 2 filters
    --------------------------------------------------------
    IF p_ic2 IS NOT NULL AND array_length(p_ic2, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(
                ARRAY(SELECT format('"itemClass2" ILIKE %L', s) FROM unnest(p_ic2) s),
                ' OR '
            ) || ') ';
    END IF;
 
    IF p_not_ic2 IS NOT NULL AND array_length(p_not_ic2, 1) > 0 THEN
        v_where := v_where || ' AND NOT (' ||
            array_to_string(
                ARRAY(SELECT format('"itemClass2" ILIKE %L', s) FROM unnest(p_not_ic2) s),
                ' OR '
            ) || ') ';
    END IF;
 
    --------------------------------------------------------
    -- Item Class 3 filters
    --------------------------------------------------------
    IF p_ic3 IS NOT NULL AND array_length(p_ic3, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(
                ARRAY(SELECT format('"itemClass3" ILIKE %L', s) FROM unnest(p_ic3) s),
                ' OR '
            ) || ') ';
    END IF;
 
    IF p_not_ic3 IS NOT NULL AND array_length(p_not_ic3, 1) > 0 THEN
        v_where := v_where || ' AND NOT (' ||
            array_to_string(
                ARRAY(SELECT format('"itemClass3" ILIKE %L', s) FROM unnest(p_not_ic3) s),
                ' OR '
            ) || ') ';
    END IF;
 
    --------------------------------------------------------
    -- Item Class 4 filters
    --------------------------------------------------------
    IF p_ic4 IS NOT NULL AND array_length(p_ic4, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(
                ARRAY(SELECT format('"itemClass4" ILIKE %L', s) FROM unnest(p_ic4) s),
                ' OR '
            ) || ') ';
    END IF;
 
    IF p_not_ic4 IS NOT NULL AND array_length(p_not_ic4, 1) > 0 THEN
        v_where := v_where || ' AND NOT (' ||
            array_to_string(
                ARRAY(SELECT format('"itemClass4" ILIKE %L', s) FROM unnest(p_not_ic4) s),
                ' OR '
            ) || ') ';
    END IF;
      v_sql := '
    WITH filtered AS (
        SELECT "sku",
        "partNo",
        "country",
        "itemClass1",
        "showRoomIndicator",
        "clearance",
        "createdAt"
        FROM "tProducts"
        ' || v_where || '
    )
   SELECT  
    f."sku"::TEXT,
    f."partNo"::TEXT,
    f."country"::TEXT,
    f."itemClass1"::TEXT,
    f."showRoomIndicator"::TEXT,
    f."clearance"::TEXT
    FROM filtered f   
  WHERE 
      (' || v_isnew_cond || ')
    ';
 
    
    -- execute
    RETURN QUERY EXECUTE v_sql;
 
END;
$BODY$;

