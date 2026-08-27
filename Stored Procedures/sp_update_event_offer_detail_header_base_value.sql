-- PROCEDURE: public.sp_update_event_offer_detail_header_base_value(integer, integer, integer, numeric)

-- DROP PROCEDURE IF EXISTS public.sp_update_event_offer_detail_header_base_value(integer, integer, integer, numeric);

CREATE OR REPLACE PROCEDURE public.sp_update_event_offer_detail_header_base_value(
	IN p_offer_id integer,
	IN p_offer_no integer,
	IN p_offer_type_id integer,
	IN p_space_purchase numeric)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE 
    v_gst numeric;
    v_startdate date;
    v_enddate date;
    v_country text;
BEGIN
	  ------------------------------------------------------------------
    SELECT 
        eh."startDate", 
        eh."endDate", 
        eh."country"
    INTO 
        v_startdate, 
        v_enddate, 
        v_country
    FROM "tEventOffer" eoh
    JOIN "tEvent" eh ON eh."eventId" = eoh."eventId"
    WHERE eoh."offerId" = p_offer_id
      AND eoh."offerNumber" = p_offer_no
    LIMIT 1;

    ------------------------------------------------------------------
    -- 2) Get GST for that country + event date
    ------------------------------------------------------------------
    SELECT (c."configvalue"->>'GST')::numeric
    INTO v_gst
    FROM "tConfig" c
    WHERE c."configtype" = 'GST'
      AND c."country" LIKE v_country || '%'
      AND v_startdate >= (c."configvalue"->>'StartDate')::date
      AND v_startdate <= COALESCE((c."configvalue"->>'EndDate')::date, '9999-12-31')
    ORDER BY (c."configvalue"->>'StartDate')::date DESC
    LIMIT 1;
	  ------------------------------------------------------------------
   
    -- ======================================================
    -- 1. Override savePercent & incrementalPercentage
    -- ======================================================
	IF p_offer_type_id = 6 THEN
    UPDATE "tEventOffer"
    SET 
		"spacePurchase" = p_space_purchase
    WHERE "offerId" = p_offer_id
      AND "offerNumber" = p_offer_no
      AND "OfferTypeId" = p_offer_type_id;

    -- ======================================================
    -- 2. Update Event Offer Detail (same CTE logic as given)
    -- ======================================================

    WITH updateEventOfferDtlForPCTOffRange AS (
        SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
			eoh."OfferTypeId",
			eoh."spacePurchase",
             eoh."savePercent",
              eoh."incrementalPercentage",
            eod."everydayUnits",
			eoh."advertisedPriceGst",
            eod."categoryforecast",
			eod."everydayPriceGst",
			eod."everydayPrice",
			eod."nationalAverageCost" as "nationalAvgCost",
			v_gst as gst_value
             FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId" 
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
          WHERE eoh."offerId" = p_offer_id
          AND eoh."offerNumber" = p_offer_no
          AND eoh."OfferTypeId" = p_offer_type_id
    ),

    calculationsForEventOfferDtlPCTOffRange AS (
        SELECT
            d.*,
            d."categoryforecast"
             AS categoryFcst,
            ROUND((d."everydayPriceGst" * d."savePercent")/100
                ,2)
            AS new_advertisedPriceGst,
            ROUND((d."everydayPriceGst" * d."savePercent")/100
                    / (1+COALESCE(d.gst_value,0))
                ,2)
             AS new_advertisedPrice,
			 ROUND(d."nationalAvgCost",2) as natAvgCost,
			 d."everydayPriceGst" as new_everydayPriceGst
        FROM updateEventOfferDtlForPCTOffRange d
    )
    UPDATE "tEventOfferDetail" e
    SET
       
         "forecastTradeMargin$" = ROUND(
        (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(c.new_advertisedPrice, 0), 2))
         - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)
        + COALESCE(p_space_purchase, 0)
        + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
        + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
    	2),
       
        "incrementalTrade$" =  ROUND(
		    (
		        ((ROUND(COALESCE(c.new_advertisedPriceGst, 0) - COALESCE(e."everydayCost", 0), 2)
		          - ROUND(COALESCE(c.new_advertisedPriceGst, 0) - COALESCE(e."everydayCost", 0), 2))
		          * COALESCE(c.categoryFcst, 0))
		        + COALESCE(p_space_purchase, 0)
		        + (COALESCE(e."scanSupport%", 0) * COALESCE(c.categoryFcst, 0))
		        + (COALESCE(e."scanSupport$", 0) * COALESCE(c.categoryFcst, 0))
		    ), 2),
        "forecastTradeMargin%" = CASE 
        WHEN ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(c.new_advertisedPrice, 0), 2) > 0
        THEN 
            
               ROUND(ROUND(
                    (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(ROUND(c.new_advertisedPriceGst / (1 + COALESCE(c.gst_value, 0)),2), 0), 2)
                      - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2))
                    + COALESCE(p_space_purchase, 0)
                    + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
                    + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
                2)
            / ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(ROUND(c.new_advertisedPriceGst / (1 + COALESCE(c.gst_value, 0)),2), 0), 2) * 100,2)
        
        ELSE 0
		END
    FROM calculationsForEventOfferDtlPCTOffRange c
    WHERE e."sku" = c."sku"
      AND e."offerId" = p_offer_id
      AND e."offerNo" = p_offer_no;

    -- ======================================================
    -- 3. Rollup summary into tEventOffer  
    -- ======================================================

    WITH EventOfferDtlSummaryForPCTOffRange  AS (
         SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,

        -- Forecast metrics
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)             AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)            AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)     AS "forecastTradeMargin$",
        ROUND(SUM(COALESCE(d."forecastTradeMargin%", 0)), 2)     AS "forecastTradeMargin%",

        -- Units and incremental
        SUM(COALESCE(d."everydayUnits", 0))                      AS "everydayUnits",
        SUM(COALESCE(d."categoryforecast", 0))                   AS "forecastUnits",
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)        AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)         AS "incrementalSales$",

        -- Scan support
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        SUM((COALESCE(d."nationalAverageCost", 0) * COALESCE(d."scanSupport%", 0)) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport%",

        MAX(d."advertisedPriceGst")                 AS "advPrice",
        MIN(d."calculatedSaveValue")        AS "saveValue",
        MIN(d."everydayPriceGst")              AS "everydayPrice",
        MIN(d."calculatedSavePercentage") AS "savePercent"
		
    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"

    WHERE  (o."OfferTypeId" IN (6))
	
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
    GROUP BY d."offerId", d."eventId", d."offerNo", v_gst
)
UPDATE public."tEventOffer" AS o
SET
    -- Forecast metrics
    "forecastCost"          = s."forecastCost",
    "forecastSales"         = s."forecastSales",
    "forecastTradeMargin$"  = s."forecastTradeMargin$",
    "forecastTradeMargin%"  = s."forecastTradeMargin%",

    -- Units and incremental
    "everydayUnits"         = s."everydayUnits",
    "forecastUnits"         = CAST(s."forecastUnits" AS int),
    "incrementalTm$"        = s."incrementalTm$",
    "incrementalSales$"     = s."incrementalSales$",
    "incrementalUnits"      = CAST((s."forecastUnits" - s."everydayUnits") AS int),

    -- Scan supports
    "totalScanSupport$"     = s."totalScanSupport$",
    "totalScanSupport%"     = s."totalScanSupport%",

    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2),
    "everydayPriceGst"      = ROUND(s."everydayPrice", 2),
    "calculatedSavePercent" = ROUND(s."savePercent", 2),

    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForPCTOffRange s
WHERE o."offerId" = s."offerId"
  AND o."offerNumber" = s."offerNo";
	END IF;

	IF p_offer_type_id = 14 THEN
	UPDATE "tEventOffer"
	 SET 
		"spacePurchase" = p_space_purchase
    WHERE "offerId" = p_offer_id
      AND "offerNumber" = p_offer_no
      AND "OfferTypeId" = p_offer_type_id;
	  
     WITH updateEventOfferDtlForComboList_STDRangePrice AS (
	 
	  SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
			eoh."OfferTypeId",
             eoh."savePercent",
              eoh."incrementalPercentage",
            eod."everydayUnits",
            eod."categoryforecast",
			eod."everydayPriceGst",
			eod."everydayPrice",
			eoh."advertisedPriceGst" ,
			eod."nationalAverageCost" as "nationalAvgCost",
			v_gst as gst_value
             FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId" 
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
          WHERE eoh."offerId" = p_offer_id
          AND eoh."offerNumber" = p_offer_no
          AND eoh."OfferTypeId" = p_offer_type_id
    ),

    calculationsForEventOfferDtlComboList_STDRangePrice AS (
        SELECT
            d.*,
			d."everydayPriceGst" as new_everydayPriceGst,
			d."categoryforecast"  as categoryFcst,
			 d."advertisedPriceGst" AS new_advertisedPriceGst,
			ROUND((d."advertisedPriceGst")/(1+ COALESCE(d.gst_value, 0)),2)  AS new_advertisedPrice,
			ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM updateEventOfferDtlForComboList_STDRangePrice d
    )
    UPDATE "tEventOfferDetail" e
    SET
        
         "forecastTradeMargin$" = ROUND(
        (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(c.new_advertisedPrice, 0), 2)
         - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2))
        + COALESCE(p_space_purchase, 0)
        + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
        + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
    	2),
        "incrementalTrade$" =  ROUND(
		    (
		        ((ROUND(COALESCE(c.new_advertisedPriceGst, 0) - COALESCE(e."everydayCost", 0), 2)
		          - ROUND(COALESCE(c.new_everydayPriceGst, 0) - COALESCE(e."everydayCost", 0), 2))
		          * COALESCE(c.categoryFcst, 0))
		        + COALESCE(p_space_purchase, 0)
		        + (COALESCE(e."scanSupport%", 0) * COALESCE(c.categoryFcst, 0))
		        + (COALESCE(e."scanSupport$", 0) * COALESCE(c.categoryFcst, 0))
		    ), 2),
        "forecastTradeMargin%" = CASE 
        WHEN ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(new_advertisedPrice, 0), 2) > 0
        THEN 
            
               ROUND(ROUND(
                    (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(new_advertisedPrice, 0), 2)
                      - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2))
                    + COALESCE(p_space_purchase, 0)
                    + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
                    + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
                2)
            / ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(new_advertisedPrice, 0), 2) * 100,2)
        
        ELSE 0
		END
    FROM calculationsForEventOfferDtlComboList_STDRangePrice c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId" IN (14);
	-- COMBO SKU LIST & STD RANGE PRICE
WITH EventOfferDtlSummaryForComboList_StdRangePrice AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,
		 d."clearanceIndicator",
        -- Forecast metrics
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)             AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)            AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)     AS "forecastTradeMargin$",
        ROUND(SUM(COALESCE(d."forecastTradeMargin%", 0)), 2)     AS "forecastTradeMargin%",

        -- Units and incremental
        SUM(COALESCE(d."everydayUnits", 0))                      AS "everydayUnits",
        SUM(COALESCE(d."categoryforecast", 0))                   AS "forecastUnits",
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)        AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)         AS "incrementalSales$",

        -- Scan support
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        SUM((COALESCE(d."nationalAverageCost", 0) * COALESCE(d."scanSupport%", 0)) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport%",

        -- Pricing logic as per C#
        MAX(d."advertisedPriceGst")                 AS "advPrice",
        MIN(d."calculatedSaveValue")        AS "saveValue",
        MIN(d."everydayPriceGst")              AS "everydayPrice",
        MIN(d."calculatedSavePercentage") AS "savePercent"
		   
    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"

    WHERE  (o."OfferTypeId" IN (14))
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
     AND (d."clearanceIndicator" <> 'Y' OR d."clearanceIndicator" IS NULL)
    GROUP BY d."offerId", d."eventId",  d."clearanceIndicator", d."offerNo", v_gst
)
UPDATE public."tEventOffer" AS o
SET
    -- Forecast metrics
    "forecastCost"          = s."forecastCost",
    "forecastSales"         = s."forecastSales",
    "forecastTradeMargin$"  = s."forecastTradeMargin$",
    "forecastTradeMargin%"  = s."forecastTradeMargin%",

    -- Units and incremental
    "everydayUnits"         = s."everydayUnits",
    "forecastUnits"         = CAST(s."forecastUnits" AS int),
    "incrementalTm$"        = s."incrementalTm$",
    "incrementalSales$"     = s."incrementalSales$",
    "incrementalUnits"      = CAST((s."forecastUnits" - s."everydayUnits") AS int),

    -- Scan supports
    "totalScanSupport$"     = s."totalScanSupport$",
    "totalScanSupport%"     = s."totalScanSupport%",

    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2),
    "everydayPriceGst"      = ROUND(s."everydayPrice", 2),
    "savePercent" = ROUND(s."savePercent", 2),

    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForComboList_StdRangePrice s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";
	END IF;
	
		IF p_offer_type_id = 25 THEN

		 UPDATE "tEventOffer"
	 SET 
		"spacePurchase" = p_space_purchase
    WHERE "offerId" = p_offer_id
      AND "offerNumber" = p_offer_no
      AND "OfferTypeId" = p_offer_type_id;
	  
     WITH updateEventOfferDtlForComboList_STDRangePrice AS (
	
       SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
			eoh."OfferTypeId",
             eoh."savePercent",
              eoh."incrementalPercentage",
            eod."everydayUnits",
            eod."categoryforecast",
			eod."everydayPriceGst",
			eod."everydayPrice",
			eoh."advertisedPriceGst" ,
			eod."nationalAverageCost" as "nationalAvgCost",
			v_gst as gst_value
             FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId" 
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
          WHERE eoh."offerId" = p_offer_id
          AND eoh."offerNumber" = p_offer_no
          AND eoh."OfferTypeId" = p_offer_type_id
    ),

    calculationsForEventOfferDtlComboList_STDRangePrice AS (
        SELECT
            d.*,
			d."everydayPriceGst" as new_everydayPriceGst,
			d."categoryforecast"  as categoryFcst,
			 d."advertisedPriceGst" AS new_advertisedPriceGst,
			ROUND((d."advertisedPriceGst")/(1+ COALESCE(d.gst_value, 0)),2)  AS new_advertisedPrice,
			ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM updateEventOfferDtlForComboList_STDRangePrice d
    )
    UPDATE "tEventOfferDetail" e
    SET
       
         "forecastTradeMargin$" = ROUND(
        (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(new_advertisedPrice, 0), 2)
         - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2))
        + COALESCE(p_space_purchase, 0)
        + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
        + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
    	2),
        "incrementalTrade$" =  ROUND(
		    (
		        ((ROUND(COALESCE(c.new_advertisedPriceGst, 0) - COALESCE(e."everydayCost", 0), 2)
		          - ROUND(COALESCE(c.new_everydayPriceGst, 0) - COALESCE(e."everydayCost", 0), 2))
		          * COALESCE(c.categoryFcst, 0))
		        + COALESCE(p_space_purchase, 0)
		        + (COALESCE(e."scanSupport%", 0) * COALESCE(c.categoryFcst, 0))
		        + (COALESCE(e."scanSupport$", 0) * COALESCE(c.categoryFcst, 0))
		    ), 2),
        "forecastTradeMargin%" = CASE 
        WHEN ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(new_advertisedPrice, 0), 2) > 0
        THEN 
            
               ROUND(ROUND(
                    (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(new_advertisedPrice, 0), 2)
                      - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2))
                    + COALESCE(p_space_purchase, 0)
                    + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
                    + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
                2)
            / ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(new_advertisedPrice, 0), 2) * 100,2)
        
        ELSE 0
		END
    FROM calculationsForEventOfferDtlComboList_STDRangePrice c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId" IN (25);
	-- COMBO SKU LIST & STD RANGE PRICE
WITH EventOfferDtlSummaryForComboList_StdRangePrice AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,
		 d."clearanceIndicator",
        -- Forecast metrics
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)             AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)            AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)     AS "forecastTradeMargin$",
        ROUND(SUM(COALESCE(d."forecastTradeMargin%", 0)), 2)     AS "forecastTradeMargin%",

        -- Units and incremental
        SUM(COALESCE(d."everydayUnits", 0))                      AS "everydayUnits",
        SUM(COALESCE(d."categoryforecast", 0))                   AS "forecastUnits",
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)        AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)         AS "incrementalSales$",

        -- Scan support
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        SUM((COALESCE(d."nationalAverageCost", 0) * COALESCE(d."scanSupport%", 0)) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport%",

        -- Pricing logic as per C#
        MAX(d."advertisedPriceGst")                 AS "advPrice",
        MIN(d."calculatedSaveValue")        AS "saveValue",
        MIN(d."everydayPriceGst")              AS "everydayPrice",
        MIN(d."calculatedSavePercentage") AS "savePercent"
		   
    FROM public."tEventOfferDetail" d
     INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"

    WHERE  (o."OfferTypeId" IN (25))
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
     AND (d."clearanceIndicator" <> 'Y' OR d."clearanceIndicator" IS NULL)
    GROUP BY d."offerId", d."eventId", d."clearanceIndicator", d."offerNo", v_gst
)
UPDATE public."tEventOffer" AS o
SET
    -- Forecast metrics
    "forecastCost"          = s."forecastCost",
    "forecastSales"         = s."forecastSales",
    "forecastTradeMargin$"  = s."forecastTradeMargin$",
    "forecastTradeMargin%"  = s."forecastTradeMargin%",

    -- Units and incremental
    "everydayUnits"         = s."everydayUnits",
    "forecastUnits"         = CAST(s."forecastUnits" AS int),
    "incrementalTm$"        = s."incrementalTm$",
    "incrementalSales$"     = s."incrementalSales$",
    "incrementalUnits"      = CAST((s."forecastUnits" - s."everydayUnits") AS int),

    -- Scan supports
    "totalScanSupport$"     = s."totalScanSupport$",
    "totalScanSupport%"     = s."totalScanSupport%",

    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2),
    "everydayPriceGst"      = ROUND(s."everydayPrice", 2),
    "savePercent" = ROUND(s."savePercent", 2),

    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" 
FROM EventOfferDtlSummaryForComboList_StdRangePrice s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";
	END IF;
	
	IF p_offer_type_id = 15 THEN
	UPDATE "tEventOffer"
	 SET 
		"spacePurchase" = p_space_purchase
    WHERE "offerId" = p_offer_id
      AND "offerNumber" = p_offer_no
      AND "OfferTypeId" = p_offer_type_id;
	 WITH updateEventOfferDtlForMultiBuySKUList AS (
         SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
			eoh."OfferTypeId",
             eoh."savePercent",
              eoh."incrementalPercentage",
            eod."everydayUnits",
            eod."categoryforecast",
			eod."everydayPriceGst",
			eoh."advertisedPriceGst" ,
			eod."everydayPrice",
			eod."nationalAverageCost" as "nationalAvgCost",
			v_gst as gst_value
             FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId" 
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
          WHERE eoh."offerId" = p_offer_id
          AND eoh."offerNumber" = p_offer_no
          AND eoh."OfferTypeId" = p_offer_type_id
    ),

    calculationsForEventOfferDtlMultiBuySKUList AS (
        SELECT
            d.*,
			d."everydayPriceGst" as new_everydayPriceGst,
			d."categoryforecast"  as categoryFcst,
			 d."advertisedPriceGst" AS new_advertisedPriceGst,
			ROUND((d."advertisedPriceGst")/(1+ COALESCE(d.gst_value, 0)),2)  AS new_advertisedPrice,
			ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM updateEventOfferDtlForMultiBuySKUList d
    )
    UPDATE "tEventOfferDetail" e
    SET
      
         "forecastTradeMargin$" = ROUND(
        (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(c.new_advertisedPrice, 0), 2)
         - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2))
        + COALESCE(p_space_purchase, 0)
        + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
        + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
    	2),
        "incrementalTrade$" =  ROUND(
		    (
		        ((ROUND(COALESCE(c.new_advertisedPriceGst, 0) - COALESCE(e."everydayCost", 0), 2)
		          - ROUND(COALESCE(e."everydayPriceGst", 0) - COALESCE(e."everydayCost", 0), 2))
		          * COALESCE(c.categoryFcst, 0))
		        + COALESCE(p_space_purchase, 0)
		        + (COALESCE(e."scanSupport%", 0) * COALESCE(c.categoryFcst, 0))
		        + (COALESCE(e."scanSupport$", 0) * COALESCE(c.categoryFcst, 0))
		    ), 2),
        "forecastTradeMargin%" = CASE 
        WHEN ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(c.new_advertisedPrice, 0), 2) > 0
        THEN 
            
               ROUND(ROUND(
                    (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(c.new_advertisedPrice, 0), 2)
                      - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2))
                    + COALESCE(p_space_purchase, 0)
                    + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
                    + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
                2)
            / ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(c.new_advertisedPrice, 0), 2) * 100,2)
        
        ELSE 0
		END
    FROM calculationsForEventOfferDtlMultiBuySKUList c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId" IN (15);

	  WITH EventOfferDtlSummaryForMultiBuySKUList AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,

        -- Forecast metrics
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)             AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)            AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)     AS "forecastTradeMargin$",
        ROUND(SUM(COALESCE(d."forecastTradeMargin%", 0)), 2)     AS "forecastTradeMargin%",

        -- Units and incremental
        SUM(COALESCE(d."everydayUnits", 0))                      AS "everydayUnits",
        SUM(COALESCE(d."categoryforecast", 0))                   AS "forecastUnits",
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)        AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)         AS "incrementalSales$",

        -- Scan support
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        SUM((COALESCE(d."nationalAverageCost", 0) * COALESCE(d."scanSupport%", 0)) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport%",

        -- Pricing logic as per C#
        MAX(d."advertisedPriceGst")                 AS "advPrice",
        MIN(d."calculatedSaveValue")        AS "saveValue",
        MIN(d."everydayPriceGst")              AS "everydayPrice",
        MIN(d."calculatedSavePercentage") AS "savePercent"
		   
    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"

    WHERE  (o."OfferTypeId" IN (15))
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
	 AND (d."clearanceIndicator" <> 'Y' OR d."clearanceIndicator" IS NULL)
    GROUP BY d."offerId", d."eventId",  d."clearanceIndicator", d."offerNo", v_gst
)
UPDATE public."tEventOffer" AS o
SET
    -- Forecast metrics
    "forecastCost"          = s."forecastCost",
    "forecastSales"         = s."forecastSales",
    "forecastTradeMargin$"  = s."forecastTradeMargin$",
    "forecastTradeMargin%"  = s."forecastTradeMargin%",

    -- Units and incremental
    "everydayUnits"         = s."everydayUnits",
    "forecastUnits"         = CAST(s."forecastUnits" AS int),
    "incrementalTm$"        = s."incrementalTm$",
    "incrementalSales$"     = s."incrementalSales$",
    "incrementalUnits"      = CAST((s."forecastUnits" - s."everydayUnits") AS int),

    -- Scan supports
    "totalScanSupport$"     = s."totalScanSupport$",
    "totalScanSupport%"     = s."totalScanSupport%",

    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2)* o."requiredQuantity",
    "everydayPriceGst"      = ROUND(s."everydayPrice", 2),
    "calculatedSavePercent" = ROUND(s."savePercent", 2),

    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForMultiBuySKUList s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";
END IF;

	IF p_offer_type_id = 23 THEN
	UPDATE "tEventOffer"
	 SET 
		"spacePurchase" = p_space_purchase
    WHERE "offerId" = p_offer_id
      AND "offerNumber" = p_offer_no
      AND "OfferTypeId" = p_offer_type_id;

	   WITH updateEventOfferDtlForPriceOnlySKUList AS (
          SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
			eoh."OfferTypeId",
             eoh."savePercent",
              eoh."incrementalPercentage",
            eod."everydayUnits",
            eod."categoryforecast",
			eod."everydayPriceGst",
			eod."everydayPrice",
			eoh."advertisedPriceGst",
			eod."nationalAverageCost" as "nationalAvgCost",
			v_gst as gst_value
             FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId" 
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
          WHERE eoh."offerId" = p_offer_id
          AND eoh."offerNumber" = p_offer_no
          AND eoh."OfferTypeId" = p_offer_type_id
    ),

    calculationsForEventOfferDtlPriceOnlySKUList AS (
        SELECT
  d.*,
  			d."everydayPriceGst" as new_everydayPriceGst,
			d."categoryforecast"  as categoryFcst,
			 d."advertisedPriceGst" AS new_advertisedPriceGst,
			ROUND((d."advertisedPriceGst")/(1+ COALESCE(d.gst_value, 0)),2)  AS new_advertisedPrice,
			ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM updateEventOfferDtlForPriceOnlySKUList d
    )
    ---Price Only (SKU LISt)
    UPDATE "tEventOfferDetail" e
    SET
       
         "forecastTradeMargin$" = ROUND(
        (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2), 0), 2)
         - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2))
        + COALESCE(p_space_purchase, 0)
        + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
        + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
    	2),
      "incrementalTrade$" =  ROUND(
		    (
		        ((ROUND(COALESCE(c.new_everydayPriceGst, 0) - COALESCE(e."everydayCost", 0), 2)
		          - ROUND(COALESCE(c.new_everydayPriceGst, 0) - COALESCE(e."everydayCost", 0), 2))
		          * COALESCE(c.categoryFcst, 0))
		        + COALESCE(p_space_purchase, 0)
		        + (COALESCE(e."scanSupport%", 0) * COALESCE(c.categoryFcst, 0))
		        + (COALESCE(e."scanSupport$", 0) * COALESCE(c.categoryFcst, 0))
		    ), 2),
        "forecastTradeMargin%" = CASE 
        WHEN ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2), 0), 2) > 0
        THEN 
            
               ROUND(ROUND(
                    (ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2), 0), 2)
                      - ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2))
                    + COALESCE(p_space_purchase, 0)
                    + ((COALESCE(e."scanSupport%", 0)) * (ROUND(c.natAvgCost * COALESCE(c.categoryFcst, 0), 2)))
                    + ((COALESCE(e."scanSupport$", 0)) * COALESCE(c.categoryFcst, 0)),
                2)
            / ROUND(COALESCE(c.categoryFcst, 0) * COALESCE(Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2), 0), 2) * 100,2)
        
        ELSE 0
		END
    FROM calculationsForEventOfferDtlPriceOnlySKUList c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId"=23;

 WITH EventOfferDtlSummaryForPriceOnlySKUList AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
		v_gst AS gst_value,
        -- Summed forecast values
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)              AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)             AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)      AS "forecastTradeMargin$",
        CASE
            WHEN SUM(COALESCE(d."forecastSales", 0)) > 0
            THEN ROUND(
                (SUM(COALESCE(d."forecastTradeMargin$", 0)) / SUM(COALESCE(d."forecastSales", 0))) * 100,
            2)
            ELSE 0
        END AS "forecastTradeMargin%",
		
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)         AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)          AS "incrementalSales$",

        -- Units and forecast
        SUM(COALESCE(d."everydayUnits", 0))                       AS "everydayUnits",
        SUM(COALESCE(d."categoryforecast", 0))                    AS "forecastUnits",

        -- Scan supports
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        SUM((COALESCE(d."nationalAverageCost", 0) * COALESCE(d."scanSupport%", 0)) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport%",

        -- Pricing
        MIN(d."everydayPriceGst")                       AS "everydayPrice",
        MIN(d."advertisedPriceGst")                  AS "advPrice",
        SUM(COALESCE(d."calculatedSaveValue", 0))                 AS "saveValue",
		MIN(d."calculatedSavePercentage")                 AS "savePercent"
		
    FROM public."tEventOfferDetail" d
     INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"

    WHERE  (o."OfferTypeId" IN (23))
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
    GROUP BY d."offerId", d."eventId",  d."offerNo", v_gst
)
UPDATE public."tEventOffer" AS o
SET
    -- Forecast metrics
    "forecastCost"          = s."forecastCost",
    "forecastSales"         = s."forecastSales",
    "forecastTradeMargin$"  = s."forecastTradeMargin$",
    "forecastTradeMargin%"  = s."forecastTradeMargin%",

    -- Units and incremental
    "everydayUnits"         = s."everydayUnits",
    "forecastUnits"         = CAST(s."forecastUnits" AS int),
    "incrementalTm$"        = s."incrementalTm$",
    "incrementalSales$"     = s."incrementalSales$",
    "incrementalUnits"      = CAST((s."forecastUnits" - s."everydayUnits") AS int),

    -- Scan supports
    "totalScanSupport$"     = s."totalScanSupport$",
    "totalScanSupport%"     = s."totalScanSupport%",

    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2),
	"savePercent"             = ROUND(s."savePercent", 2),
    "everydayPriceGst"      = ROUND(s."everydayPrice", 2),

    -- Supplier income (derived)23

    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForPriceOnlySKUList s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";
END IF;
END;
$BODY$;