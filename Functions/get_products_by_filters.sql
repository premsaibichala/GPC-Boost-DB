DROP FUNCTION IF EXISTS public.get_products_by_filters(integer, text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], boolean, boolean, boolean, integer, integer, integer, timestamp without time zone, boolean, boolean, boolean, boolean, boolean, boolean, boolean, integer, integer);

-- FUNCTION: public.get_products_by_filters(integer, text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], boolean, boolean, boolean, boolean, integer, integer, integer, timestamp without time zone, boolean, boolean, boolean, boolean, boolean, boolean, boolean, integer, integer)
-- DROP FUNCTION IF EXISTS public.get_products_by_filters(integer, text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], text[], boolean, boolean, boolean, boolean, integer, integer, integer, timestamp without time zone, boolean, boolean, boolean, boolean, boolean, boolean, boolean, integer, integer);

CREATE OR REPLACE FUNCTION public.get_products_by_filters(
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
	p_part_descriptions text[] DEFAULT NULL::text[],
	p_selected boolean DEFAULT false,
	p_new boolean DEFAULT false,
	p_duplicates boolean DEFAULT false,
	p_is_edited boolean DEFAULT NULL::boolean,
	p_offerid integer DEFAULT NULL::integer,
	p_offerno integer DEFAULT NULL::integer,
	p_offertypeid integer DEFAULT NULL::integer,
	p_searchedat timestamp without time zone DEFAULT NULL::timestamp without time zone,
	p_sort_sku_desc boolean DEFAULT NULL::boolean,
	p_sort_partno_desc boolean DEFAULT NULL::boolean,
	p_sort_desc_desc boolean DEFAULT NULL::boolean,
	p_sort_brand_desc boolean DEFAULT NULL::boolean,
	p_sort_ic4_desc boolean DEFAULT NULL::boolean,
	p_sort_showroom_desc boolean DEFAULT NULL::boolean,
	p_sort_clearance_desc boolean DEFAULT NULL::boolean,
	p_page_number integer DEFAULT 1,
	p_page_size integer DEFAULT 100)
    RETURNS TABLE(sku text, part_no text, description text, brand text, itemclass4 text, showroomindicator text, clearance text, categorymanager text, itemclass1 text, country text, isnew boolean, isselected boolean, isunselected boolean, isskuactive boolean, isduplicate boolean, duplicate_offer_name text, duplicate_offer_id integer, duplicate_page integer, duplicate_page_position integer, total_count integer, event_offer_count integer, new_count integer, duplicate_count integer) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    v_sql TEXT;
    v_where TEXT := '
    WHERE UPPER(country) = UPPER(
        (
            SELECT country
            FROM "tEvent"
            WHERE "eventId" = ' || p_event_id || '
        )
    )';
    v_order TEXT := ' ORDER BY e."offerNo" ';  -- default
    v_offset INT := (p_page_number - 1) * p_page_size;
	v_searched_at_date_literal TEXT;
    v_isnew_cond TEXT;   -- boolean condition as TEXT
	v_new_count INT;
	v_eventOffer_count INT;
	v_new_count_sql TEXT := '';
	v_offer_skus_subquery TEXT;   -- SKUs that belong to the current offer (edited filter)
	v_where_new_skus TEXT := ' WHERE UPPER(country) = UPPER((SELECT country FROM "tEvent"  WHERE "eventId" = ' || p_event_id || ')) AND "isActive" = TRUE ';
    v_company TEXT;
    v_duplicate_where TEXT;      -- extra exclusion condition mirroring FindDuplicateSKUsAsync
    v_filtered_skus TEXT[];      -- SKUs remaining after the filter step, computed BEFORE duplicate check
    v_duplicate_skus TEXT[];     -- subset of v_filtered_skus found to be duplicates
    v_duplicate_count INT;       -- count of v_duplicate_skus
BEGIN
    SELECT company INTO v_company FROM "tEvent" WHERE "eventId" = p_event_id;
	    v_searched_at_date_literal := CASE
        WHEN p_searchedAt IS NULL THEN 'NULL'
        ELSE quote_literal(p_searchedAt::timestamp)    -- e.g. '2025-11-29'
    END;
    -- build the isNew boolean condition (as SQL text)
    -- matches C# check: DateAdded exists AND DateAdded(date) > searchedAt(date) AND offerType in (...)
    v_isnew_cond := 
        'f."createdAt" IS NOT NULL'
        || ' AND f."createdAt"::timestamp > ' || v_searched_at_date_literal;
 
    -- SKUs that belong to the current offer (type 3 ignores offerNo)
    IF p_offerTypeId = 3 THEN
        v_offer_skus_subquery := 'SELECT "sku" FROM "tEventOfferDetail" WHERE "offerId" = '
            || COALESCE(p_offerId::text, 'NULL') || ' AND "isSkuActive" = FALSE';
    ELSE
        v_offer_skus_subquery := 'SELECT "sku" FROM "tEventOfferDetail" WHERE "offerId" = '
            || COALESCE(p_offerId::text, 'NULL')
            || ' AND "offerNo" = ' || COALESCE(p_offerNo::text, 'NULL')
            || ' AND "isSkuActive" = FALSE';
    END IF;
 
    -- Active / edited filter applied INSIDE the CTE so total_count is accurate.
    --   p_is_edited = TRUE  -> active products PLUS inactive products that exist in this offer
    --   p_is_edited = FALSE -> active products only (offer detail irrelevant to inclusion)
    IF COALESCE(p_is_edited, FALSE) THEN
        v_where := v_where || ' AND ("isActive" = TRUE OR "sku" IN (' || v_offer_skus_subquery || ')) ';
    ELSE
        v_where := v_where || ' AND "isActive" = TRUE ';
    END IF;
 
	-- Count event offers
	IF p_offerTypeId = 3 THEN
	    SELECT COUNT(*)
	    INTO v_eventOffer_count
	    FROM "tEventOfferDetail"
	    WHERE "offerId" = p_offerId;
	ELSE
	    SELECT COUNT(*)
	    INTO v_eventOffer_count
	    FROM "tEventOfferDetail"
	    WHERE "offerId" = p_offerId
	      AND "offerNo" = p_offerNo;
	END IF;
	-- Count new products

    --------------------------------------------------------
    -- Duplicate SKU detection (mirrors FindDuplicateSKUsAsync):
    --   * offerId is NULL/0            -> any other offer of the same offerTypeId with this SKU is a duplicate
    --   * offerTypeId IN (5, 25)       -> BuyXGetYFree / ComboSkuList: duplicate unless same offerId AND same offerNo
    --   * offerTypeId = 3              -> Combo: duplicate unless same offerId (offerNo ignored)
    --   * otherwise                    -> duplicate unless same offerId AND same offerNo
    --------------------------------------------------------
    v_duplicate_where := ' d."eventId" = ' || p_event_id || ' AND o."OfferTypeId" = ' || COALESCE(p_offerTypeId::text, 'NULL');

    IF COALESCE(p_offerId, 0) = 0 THEN
        NULL; -- no exclusion: any match on offerTypeId is a duplicate
    ELSIF p_offerTypeId IN (5, 25) THEN
        v_duplicate_where := v_duplicate_where
            || ' AND (o."offerId" <> ' || p_offerId
            || ' OR (o."offerId" = ' || p_offerId || ' AND o."offerNumber" <> ' || COALESCE(p_offerNo::text, 'NULL') || '))';
    ELSIF p_offerTypeId = 3 THEN
        v_duplicate_where := v_duplicate_where || ' AND o."offerId" <> ' || p_offerId;
    ELSE
        v_duplicate_where := v_duplicate_where
            || ' AND o."offerId" <> ' || p_offerId
            || ' AND o."offerNumber" <> ' || COALESCE(p_offerNo::text, 'NULL');
    END IF;

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
    IF p_supplier_names IS NOT NULL AND array_length(p_supplier_names, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(ARRAY(SELECT format('"supplierName" ILIKE %L', s || '%') FROM unnest(p_supplier_names) s), ' OR ')
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
            array_to_string(ARRAY(SELECT format('"brand" ILIKE %L', s) FROM unnest(p_not_brands) s), ' OR ')
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
 

	 IF p_part_descriptions IS NOT NULL AND array_length(p_part_descriptions, 1) > 0 THEN
        v_where := v_where || ' AND (' ||
            array_to_string(
                ARRAY(SELECT format('"description" ILIKE %L', '%' || s || '%') FROM unnest(p_part_descriptions) s),
                ' OR '
            ) || ') ';
    END IF;
   IF p_sort_sku_desc IS NOT NULL THEN
        v_order := ' ORDER BY "sku" ' || CASE WHEN p_sort_sku_desc THEN 'DESC' ELSE 'ASC' END;
    ELSIF p_sort_partno_desc IS NOT NULL THEN
        v_order := ' ORDER BY "partNo" ' || CASE WHEN p_sort_partno_desc THEN 'DESC' ELSE 'ASC' END;
    ELSIF p_sort_desc_desc IS NOT NULL THEN
        v_order := ' ORDER BY "description" ' || CASE WHEN p_sort_desc_desc THEN 'DESC' ELSE 'ASC' END;
    ELSIF p_sort_brand_desc IS NOT NULL THEN
        v_order := ' ORDER BY "brand" ' || CASE WHEN p_sort_brand_desc THEN 'DESC' ELSE 'ASC' END;
    ELSIF p_sort_ic4_desc IS NOT NULL THEN
        v_order := ' ORDER BY "itemClass4" ' || CASE WHEN p_sort_ic4_desc THEN 'DESC' ELSE 'ASC' END;
    ELSIF p_sort_showroom_desc IS NOT NULL THEN
        v_order := ' ORDER BY "showRoomIndicator" ' || CASE WHEN p_sort_showroom_desc THEN 'DESC' ELSE 'ASC' END;
    ELSIF p_sort_clearance_desc IS NOT NULL THEN
        v_order := ' ORDER BY "clearance" ' || CASE WHEN p_sort_clearance_desc THEN 'DESC' ELSE 'ASC' END;
    END IF;
    --------------------------------------------------------
    -- New product count (always restricted to active SKUs)
    --------------------------------------------------------
    v_new_count_sql := 'SELECT COUNT(*) FROM "tProducts" f '
                       || v_where_new_skus
                       || ' AND (' || v_isnew_cond || ')';
    -- Execute the new count SQL
    EXECUTE v_new_count_sql INTO v_new_count;

    --------------------------------------------------------
    -- Step 1: get the SKUs that survive the filters above (v_where is now final)
    --------------------------------------------------------
    EXECUTE 'SELECT array_agg("sku") FROM "tProducts" ' || v_where
        INTO v_filtered_skus;

    --------------------------------------------------------
    -- Step 2: check duplicates ONLY among those filtered SKUs (mirrors
    -- FindDuplicateSKUsAsync, which is called with the already-filtered SKU list)
    --------------------------------------------------------
    IF v_filtered_skus IS NOT NULL AND array_length(v_filtered_skus, 1) > 0 THEN
        EXECUTE '
            SELECT array_agg(DISTINCT d."sku")
            FROM "tEventOfferDetail" d
            JOIN "tEventOffer" o
              ON d."eventId" = o."eventId"
             AND d."page" = o."page"
             AND d."pagePosition" = o."pagePosition"
             AND d."offerId" = o."offerId"
             AND d."offerNo" = o."offerNumber"
            WHERE d."sku" = ANY($1)
              AND ' || v_duplicate_where
        INTO v_duplicate_skus
        USING v_filtered_skus;
    ELSE
        v_duplicate_skus := ARRAY[]::text[];
    END IF;

    v_duplicate_count := COALESCE(array_length(v_duplicate_skus, 1), 0);

    --------------------------------------------------------
    -- Final SQL with paging
    --------------------------------------------------------
IF p_offerTypeId = 3 THEN
v_sql := '
    WITH filtered AS (
        SELECT *,
               COUNT(*) OVER() AS total_count
        FROM "tProducts"
        ' || v_where || '
    ),
    clearance_flags AS (
        SELECT f."sku", f."country",
               MAX(CASE WHEN (pld."priceList" = ''184'' AND pld."country" = ''AU'')
                          OR (pld."priceList" = ''498'' AND pld."country" = ''NZ'')
                        THEN pld."priceListPrice" END) AS mgrspl_price,
               MAX(CASE WHEN (pld."priceList" = ''050'' AND pld."country" = ''AU'')
                          OR (pld."priceList" = ''499'' AND pld."country" = ''NZ'')
                        THEN pld."priceListPrice" END) AS clearance_price
        FROM filtered f
        LEFT JOIN "tPriceListDetail" pld
               ON pld."sku" = f."sku"
              AND pld."isActive" = TRUE
              AND pld.company = ' || quote_literal(v_company) || '
              AND pld."country" = f."country"
              AND (
                    (pld."priceList" IN (''050'',''184'') AND pld."country" = ''AU'')
                 OR (pld."priceList" IN (''498'',''499'') AND pld."country" = ''NZ'')
                  )
        GROUP BY f."sku", f."country"
    )
   SELECT
    f."sku"::TEXT,
    f."partNo"::TEXT,
    f."description"::TEXT,
    f."brand"::TEXT,
    f."itemClass4"::TEXT,
    f."showRoomIndicator"::TEXT,
    CASE
        WHEN cpl.mgrspl_price IS NOT NULL AND cpl.clearance_price IS NOT NULL THEN
            CASE WHEN cpl.clearance_price <= cpl.mgrspl_price THEN ''Clearance'' ELSE ''Mgr Special'' END
        WHEN cpl.mgrspl_price IS NOT NULL THEN ''Mgr Special''
        WHEN cpl.clearance_price IS NOT NULL THEN ''Clearance''
        ELSE ''N''
    END::TEXT AS "clearance",
    f."categoryManager"::TEXT,
    f."itemClass1"::TEXT,
    f."country"::TEXT,
    CASE WHEN ' || v_isnew_cond || ' THEN TRUE ELSE FALSE END AS isNew,
    CASE WHEN e."sku" IS NOT NULL 
         THEN TRUE ELSE FALSE END AS isSelected,
    CASE WHEN e."sku" IS NULL 
         THEN TRUE ELSE FALSE END AS isUnselected,
    COALESCE(e."isSkuActive", TRUE) AS isSkuActive,
    CASE WHEN f."sku" = ANY($1) THEN TRUE ELSE FALSE END AS isDuplicate,
    -- 15, 16, 17: COUNTS
	dup."offerName"::TEXT AS duplicate_offer_name,
	dup."offerId"::INT AS duplicate_offer_id,
	dup."page"::INT AS duplicate_page,
	dup."pagePosition"::INT AS duplicate_page_position,
    f.total_count::INT,
    '||v_eventOffer_count||'::INT AS event_offer_count,
	'||v_new_count||'::INT AS new_count,
	'||v_duplicate_count||'::INT AS duplicate_count
	
    FROM filtered f
    LEFT JOIN "tEventOfferDetail" e
           ON
		   f."sku" = e."sku"
		   AND e."offerId" = ' || COALESCE(p_offerId::text, 'NULL') || '
    LEFT JOIN clearance_flags cpl
           ON cpl."sku" = f."sku" AND cpl."country" = f."country"

    LEFT JOIN LATERAL (
        SELECT o."offerName", o."page", o."pagePosition",o."offerId"
        FROM "tEventOfferDetail" d
        JOIN "tEventOffer" o
          ON d."eventId" = o."eventId"
         AND d."page" = o."page"
         AND d."pagePosition" = o."pagePosition"
         AND d."offerId" = o."offerId"
         AND d."offerNo" = o."offerNumber"
        WHERE d."sku" = f."sku"
          AND f."sku" = ANY($1)
          AND ' || v_duplicate_where || '
        LIMIT 1
    ) dup ON TRUE
  WHERE
      (' || (CASE WHEN p_selected THEN 'e."sku" IS NOT NULL' ELSE 'TRUE' END) || ')
  AND (' || (CASE WHEN p_new THEN v_isnew_cond   ELSE 'TRUE' END) || ')
  AND (' || (CASE WHEN p_duplicates THEN 'f."sku" = ANY($1)' ELSE 'NOT (f."sku" = ANY($1))' END) || ')
  '|| v_order ||'
      OFFSET ' || v_offset || '
      LIMIT ' || p_page_size || '
    ';
ELSE
	 v_sql := '
    WITH filtered AS (
        SELECT *,
               COUNT(*) OVER() AS total_count
        FROM "tProducts"
        ' || v_where || '
    ),
    clearance_flags AS (
        SELECT f."sku", f."country",
               MAX(CASE WHEN (pld."priceList" = ''184'' AND pld."country" = ''AU'')
                          OR (pld."priceList" = ''498'' AND pld."country" = ''NZ'')
                        THEN pld."priceListPrice" END) AS mgrspl_price,
               MAX(CASE WHEN (pld."priceList" = ''050'' AND pld."country" = ''AU'')
                          OR (pld."priceList" = ''499'' AND pld."country" = ''NZ'')
                        THEN pld."priceListPrice" END) AS clearance_price
        FROM filtered f
        LEFT JOIN "tPriceListDetail" pld
               ON pld."sku" = f."sku"
              AND pld."isActive" = TRUE
              AND pld.company = ' || quote_literal(v_company) || '
              AND (
                    (pld."priceList" IN (''050'',''184'') AND pld."country" = ''AU'')
                 OR (pld."priceList" IN (''498'',''499'') AND pld."country" = ''NZ'')
                  )
        GROUP BY f."sku", f."country"
    )
   SELECT
    f."sku"::TEXT,
    f."partNo"::TEXT,
    f."description"::TEXT,
    f."brand"::TEXT,
    f."itemClass4"::TEXT,
    f."showRoomIndicator"::TEXT,
    CASE
        WHEN cpl.mgrspl_price IS NOT NULL AND cpl.clearance_price IS NOT NULL THEN
            CASE WHEN cpl.clearance_price <= cpl.mgrspl_price THEN ''Clearance'' ELSE ''Mgr Special'' END
        WHEN cpl.mgrspl_price IS NOT NULL THEN ''Mgr Special''
        WHEN cpl.clearance_price IS NOT NULL THEN ''Clearance''
        ELSE ''N''
    END::TEXT AS "clearance",
    f."categoryManager"::TEXT,
    f."itemClass1"::TEXT,
    f."country"::TEXT,
    CASE WHEN ' || v_isnew_cond || ' THEN TRUE ELSE FALSE END AS isNew,
    CASE WHEN e."sku" IS NOT NULL 
         THEN TRUE ELSE FALSE END AS isSelected,
    CASE WHEN e."sku" IS NULL 
         THEN TRUE ELSE FALSE END AS isUnselected,
	COALESCE(e."isSkuActive", TRUE) as isSkuActive,
    CASE WHEN f."sku" = ANY($1) THEN TRUE ELSE FALSE END AS isDuplicate,
    -- 15, 16, 17: COUNTS
    dup."offerName"::TEXT AS duplicate_offer_name,
	dup."offerId"::INT AS duplicate_offer_id,
	dup."page"::INT AS duplicate_page,
	dup."pagePosition"::INT AS duplicate_page_position,
    f.total_count::INT,
    '||v_eventOffer_count||'::INT AS event_offer_count,
	'||v_new_count||'::INT AS new_count,
	'||v_duplicate_count||'::INT AS duplicate_count
    FROM filtered f
    LEFT JOIN "tEventOfferDetail" e
           ON
		   f."sku" = e."sku"
		   AND e."offerId" = ' || COALESCE(p_offerId::text, 'NULL') || '
           AND e."offerNo" = ' || COALESCE(p_offerNo::text, 'NULL') || '
    LEFT JOIN clearance_flags cpl
           ON cpl."sku" = f."sku" AND cpl."country" = f."country"

    LEFT JOIN LATERAL (
        SELECT o."offerName", o."page", o."pagePosition",o."offerId"
        FROM "tEventOfferDetail" d
        JOIN "tEventOffer" o
          ON d."eventId" = o."eventId"
         AND d."page" = o."page"
         AND d."pagePosition" = o."pagePosition"
         AND d."offerId" = o."offerId"
         AND d."offerNo" = o."offerNumber"
        WHERE d."sku" = f."sku"
          AND f."sku" = ANY($1)
          AND ' || v_duplicate_where || '
        LIMIT 1
    ) dup ON TRUE
  WHERE
      (' || (CASE WHEN p_selected THEN 'e."sku" IS NOT NULL' ELSE 'TRUE' END) || ')
  AND (' || (CASE WHEN p_new THEN v_isnew_cond   ELSE 'TRUE' END) || ')
  AND (' || (CASE WHEN p_duplicates THEN 'f."sku" = ANY($1)' ELSE 'NOT (f."sku" = ANY($1))' END) || ')
  '|| v_order ||'
      OFFSET ' || v_offset || '
      LIMIT ' || p_page_size || '
    ';
END IF;
    -- execute
    RETURN QUERY EXECUTE v_sql USING COALESCE(v_duplicate_skus, ARRAY[]::text[]);
END;
$BODY$;
