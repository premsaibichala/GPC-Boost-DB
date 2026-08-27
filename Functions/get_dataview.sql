-- FUNCTION: public.get_dataview(integer, integer, text[], text[], text[], text[], boolean, boolean, boolean, boolean, integer, integer)

-- DROP FUNCTION IF EXISTS public.get_dataview(integer, integer, text[], text[], text[], text[], boolean, boolean, boolean, boolean, integer, integer);

CREATE OR REPLACE FUNCTION public.get_dataview(
	p_offer_id integer DEFAULT 1,
	p_offer_no integer DEFAULT 1,
	p_skus text[] DEFAULT NULL::text[],
	p_part_numbers text[] DEFAULT NULL::text[],
	p_brands text[] DEFAULT NULL::text[],
	p_part_descriptions text[] DEFAULT NULL::text[],
	p_sort_advpricegst_desc boolean DEFAULT NULL::boolean,
	p_sort_edpricegst_desc boolean DEFAULT NULL::boolean,
	p_sort_edunits_desc boolean DEFAULT NULL::boolean,
	p_sort_catfcst_desc boolean DEFAULT NULL::boolean,
	p_page_number integer DEFAULT 1,
	p_page_size integer DEFAULT 100)
    RETURNS TABLE(sku text, part_number text, brand text, description text, frompriceind boolean, displayind boolean, clearance text, showroom text, advpricegst numeric, edprice numeric, calcsavepercent numeric, calcsavevalue numeric, lecost numeric, natavgcost numeric, catfcst integer, incrfcst integer, fcstcost numeric, fcstsales numeric, fcsttmvalue numeric, fcsttmpercent numeric, edunits numeric, scansupportvalue numeric, scansupportpercent numeric, sohstore integer, sohdc integer, grp0qty integer, grp1qty integer, grp2qty integer, grp3qty integer, grp4qty integer, grp5qty integer, totaltieup integer, tieuppercentfcst numeric, tieupcost numeric, supplierid text, suppliername text, ic2 text, ic3 text, ic4 text, comofferic1 text, incrementaltmdollar numeric, incrementalsalesdollar numeric, edcost numeric, edunittmdollar numeric, advunittmdollar numeric, advsalesdollar numeric, edsalesdollar numeric, totalmultibuyprice numeric, requiredqty integer, advpriceexgst numeric, purchaseqty integer, freeqty integer, iscatfcstlocked boolean, total_count integer, isskuedited boolean, isskuactive boolean) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    v_sql TEXT;
    v_order TEXT := '';  -- default
    v_offset INT := (p_page_number - 1) * p_page_size;
	v_eventOffer_count INT;
	v_where TEXT := '';

BEGIN

	IF p_skus IS NOT NULL AND array_length(p_skus, 1) > 0 THEN
        v_where := v_where || '  (' ||
            array_to_string(ARRAY(SELECT format('p."sku" ILIKE %L', s || '%') FROM unnest(p_skus) s), ' OR ')
            || ') ';
    END IF;

    IF p_part_numbers IS NOT NULL AND array_length(p_part_numbers, 1) > 0 THEN
        v_where := v_where || '  (' ||
            array_to_string(ARRAY(SELECT format('p."partNo" ILIKE %L', s || '%') FROM unnest(p_part_numbers) s), ' OR ')
            || ') ';
    END IF;

 
    -- Same pattern for brand and item class filters:
    IF p_brands IS NOT NULL AND array_length(p_brands, 1) > 0 THEN
        v_where := v_where || '  (' ||
            array_to_string(ARRAY(SELECT format('p."brand" ILIKE %L',  s || '%') FROM unnest(p_brands) s), ' OR ')
            || ') ';
    END IF;

   
	IF p_part_descriptions IS NOT NULL AND array_length(p_part_descriptions, 1) > 0 THEN
        v_where := v_where || '  (' ||
            array_to_string(
                ARRAY(SELECT format('p."description" ILIKE %L', '%' || s || '%') FROM unnest(p_part_descriptions) s),
                ' OR '
            ) || ') ';
    END IF;

IF p_sort_advPriceGst_desc IS NOT NULL THEN
    v_order :=
        ' ORDER BY f."advertisedPriceGst" ' ||
        CASE WHEN p_sort_advPriceGst_desc
             THEN 'DESC NULLS LAST'
             ELSE 'ASC NULLS FIRST'
        END ;
ELSIF p_sort_edPriceGst_desc IS NOT NULL THEN
    v_order :=
        ' ORDER BY f."everydayPriceGst" ' ||
        CASE WHEN p_sort_edPriceGst_desc
             THEN 'DESC NULLS LAST'
             ELSE 'ASC NULLS FIRST'
        END ;
ELSIF p_sort_edUnits_desc IS NOT NULL THEN
    v_order :=
        ' ORDER BY f."everydayUnits" ' ||
        CASE WHEN p_sort_edUnits_desc
             THEN 'DESC NULLS LAST'
             ELSE 'ASC NULLS FIRST'
        END ;
ELSIF p_sort_catFcst_desc IS NOT NULL THEN
    v_order :=
        ' ORDER BY f."categoryforecast" ' ||
        CASE WHEN p_sort_catFcst_desc
             THEN 'DESC NULLS LAST'
             ELSE 'ASC NULLS FIRST'
        END ;
END IF;

    --------------------------------------------------------
    -- Final SQL with paging
    --------------------------------------------------------
 
 	v_sql := '
WITH filtered AS (
    SELECT
        e.sku,
        e."partNo",
        p.description,
        p.brand,
        p."itemClass1",
        p."itemClass2",
        p."itemClass3",
        p."itemClass4",
        p."supplierId",
        p."supplierName",

        e."fromPriceIndicator",
        e."displayIndicator",
        e."clearanceIndicator",
        e."showroomIndicator",

        e."advertisedPriceGst",
        e."everydayPriceGst",
        e."advertisedPriceGst" / (1+e."gst") as "advertisedPrice",

        e."LatestEffectiveCost",
        e."nationalAverageCost",

        e.categoryforecast,
        e."incrementalForecast",
        e."everydayUnits",

        e."scanSupport$",
        e."scanSupport%",
		e."gst",
        e."stockOnHandStore",
        e."stockOnHandDC",
		e."forecastCost",
		e."forecastSales",
		e."forecastTradeMargin$",
		e."forecastTradeMargin%",
        e."group0Quantity",
        e."group1Quantity",
        e."group2Quantity",
        e."group3Quantity",
        e."group4Quantity",
        e."group5Quantity",
		e."tieUpCost",
        e."totalTieUp",
        e."offerQuantity",
		e."incrementalSales",
		e."incrementalTrade$",
        e."everydayCost",
        e."isCategoryForecastLocked",
        eo."totalMultiBuyPrice",
        eo."requiredQuantity",
		eo."spacePurchase",
		e."purchaseQuantity",
		e."isSkuEdited",
        COUNT(*) OVER() AS total_count,
        e."isSkuActive"
    FROM "tEventOfferDetail" e
    JOIN "tEvent" ev
      ON e."eventId" = ev."eventId"
    JOIN "tProducts" p

      ON e.sku = p.sku
     AND p.country = ev.country
    JOIN "tEventOffer" eo
      ON e."offerId" = eo."offerId"
     AND e."offerNo" = eo."offerNumber"
     
    WHERE e."offerId" = ' || p_offer_id || '
      AND e."offerNo" = ' || p_offer_no || ' 
' || CASE
        WHEN TRIM(v_where) <> '' THEN ' AND ' || v_where
        ELSE ''
     END || '

)
SELECT
    f.sku::text                              AS sku,
    f."partNo"::text                         AS part_number,
    f.brand::text                            AS brand,
    f.description::text                      AS description,

    f."fromPriceIndicator"                   AS frompriceind,
    f."displayIndicator"                     AS displayind,
    f."clearanceIndicator"::text             AS clearance,
    f."showroomIndicator"::text              AS showroom,

    f."advertisedPriceGst"::numeric          AS advpricegst,
    f."everydayPriceGst"::numeric            AS edprice,

    ROUND(
        CASE
            WHEN f."everydayPriceGst" > 0
            THEN ((f."everydayPriceGst" - f."advertisedPriceGst")
                  / f."everydayPriceGst") * 100
            ELSE 0
        END, 2
    )::numeric                               AS calcsavepercent,

    ROUND(
        f."everydayPriceGst" - f."advertisedPriceGst", 2
    )::numeric                               AS calcsavevalue,

    ROUND(f."LatestEffectiveCost",2)::numeric         AS lecost,
    f."nationalAverageCost"::numeric         AS natavgcost,

    f.categoryforecast::int                  AS catfcst,
    f.categoryforecast::int -   f."everydayUnits"::int AS incrfcst,

    ROUND(
        f."forecastCost", 2
    )::numeric                               AS fcstcost,

    ROUND(
        f."forecastSales", 2
    )::numeric                               AS fcstsales,

    ROUND(
       f."forecastTradeMargin$",
        2
    )::numeric                               AS fcsttmvalue,

    ROUND(f."forecastTradeMargin%",2)::numeric                             AS fcsttmpercent,

    f."everydayUnits"::numeric               AS edunits,
    f."scanSupport$"::numeric                AS scansupportvalue,
    f."scanSupport%"::numeric                AS scansupportpercent,

    f."stockOnHandStore"::int                AS sohstore,
    f."stockOnHandDC"::int                   AS sohdc,

    f."group0Quantity"::int                  AS grp0qty,
    f."group1Quantity"::int                  AS grp1qty,
    f."group2Quantity"::int                  AS grp2qty,
    f."group3Quantity"::int                  AS grp3qty,
    f."group4Quantity"::int                  AS grp4qty,
    f."group5Quantity"::int                  AS grp5qty,

    f."totalTieUp"::int                      AS totaltieup,

    CASE
        WHEN f.categoryforecast > 0
        THEN ROUND(f."totalTieUp"::numeric / f.categoryforecast, 2)
        ELSE 0
    END::numeric                             AS tieuppercentfcst,

    ROUND(
        f."tieUpCost", 2
    )::numeric                               AS tieupcost,

    f."supplierId"::text                     AS supplierid,
    f."supplierName"::text                   AS suppliername,

    f."itemClass2"::text                     AS ic2,
    f."itemClass3"::text                     AS ic3,
    f."itemClass4"::text                     AS ic4,
    f."itemClass1"::text                     AS comofferic1,

ROUND(
     f."incrementalTrade$",
    2
)::numeric AS incrementaltmdollar,
    Round(f."incrementalSales",2)::numeric                               AS incrementalsalesdollar,

    f."everydayCost"::numeric                AS edcost,

    ROUND(
        f."everydayPriceGst" - f."everydayCost", 2
    )::numeric                               AS edunittmdollar,

    ROUND(
        f."advertisedPriceGst" - f."everydayCost", 2
    )::numeric                               AS advunittmdollar,

    ROUND(
        f."advertisedPriceGst" * f.categoryforecast, 2
    )::numeric                               AS advsalesdollar,

    ROUND(
        f."everydayPriceGst" * f.categoryforecast, 2
    )::numeric                               AS edsalesdollar,

    f."totalMultiBuyPrice"::numeric           AS totalmultibuyprice,
    f."requiredQuantity"::int                AS requiredqty,

    ROUND(f."advertisedPrice"::numeric,2)              AS advpriceexgst,
    f."purchaseQuantity"::int                AS purchaseqty,
    f."offerQuantity"::int                   AS freeqty,

    f."isCategoryForecastLocked"              AS iscatfcstlocked,
    f.total_count::int                       AS total_count,
	f."isSkuEdited" 					     AS isskuedited,
    f."isSkuActive"                          AS isskuactive
FROM filtered f
' ||CASE WHEN TRIM(v_order) <> '' THEN v_order ELSE 'ORDER BY f.sku' END || ' 
OFFSET ' || v_offset || '
LIMIT ' || p_page_size || ';
';

    
    -- execute
    RETURN QUERY EXECUTE v_sql;

END;
$BODY$;
