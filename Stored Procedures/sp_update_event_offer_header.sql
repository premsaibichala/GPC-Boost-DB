-- PROCEDURE: public.sp_update_event_offer_header(integer, integer, integer)

-- DROP PROCEDURE IF EXISTS public.sp_update_event_offer_header(integer, integer, integer);

CREATE OR REPLACE PROCEDURE public.sp_update_event_offer_header(
	IN p_offer_id integer,
	IN p_offer_no integer,
	IN p_offer_type_id integer)
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
    -- ======================================================
    -- 1. Override savePercent & incrementalPercentage
    -- ======================================================
	IF p_offer_type_id = 6 THEN
    WITH EventOfferDtlSummaryforAdvPriceForPCTOffRange  AS (
         SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,
		d."clearanceIndicator",
       
	   MIN(d."advertisedPriceGst")                 AS "advPrice",
        MIN(d."calculatedSaveValue")        AS "saveValue",
        MIN(d."everydayPriceGst")              AS "everydayPrice",
        MIN(d."calculatedSavePercentage") AS "savePercent"
		
    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"
    WHERE  (o."OfferTypeId" IN (6))
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
	  AND (d."clearanceIndicator" <> 'Y' OR d."clearanceIndicator" IS NULL)
      AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId", d."offerNo", d."clearanceIndicator"
)
UPDATE public."tEventOffer" AS o
SET
    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2),
    "everydayPriceGst"      = ROUND(s."everydayPrice", 2),
	"everydayPrice"         = ROUND(s."everydayPrice" / (1 + s.gst_value), 2),
    "calculatedSavePercent" = ROUND(s."savePercent", 2)
	
FROM EventOfferDtlSummaryforAdvPriceForPCTOffRange s
WHERE o."offerId" = s."offerId"
  AND o."offerNumber" = s."offerNo";

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
         CASE
            WHEN SUM(COALESCE(d."forecastSales", 0)) > 0
            THEN ROUND(
                (SUM(COALESCE(d."forecastTradeMargin$", 0)) / SUM(COALESCE(d."forecastSales", 0))) * 100,
            2)
            ELSE 0
        END AS "forecastTradeMargin%",
        -- Units and incremental
        SUM(COALESCE(d."everydayUnits", 0))                      AS "everydayUnits",
        SUM(COALESCE(d."categoryforecast", 0))                   AS "forecastUnits",
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)        AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)         AS "incrementalSales$",

        -- Scan support
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        ROUND(SUM((COALESCE(d."LatestEffectiveCost", 0) * (COALESCE(d."scanSupport%", 0)/100) * COALESCE(d."categoryforecast", 0))),2) AS "totalScanSupport%"
		
    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"
    WHERE  (o."OfferTypeId" IN (6))
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
       AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId", d."offerNo"
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

    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForPCTOffRange s
WHERE o."offerId" = s."offerId"
  AND o."offerNumber" = s."offerNo";
	END IF;

		IF p_offer_type_id = 14 THEN

WITH EventOfferDtlSummaryForStdRangePrice AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,
        -- Forecast metrics
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)             AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)            AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)     AS "forecastTradeMargin$",
         CASE
            WHEN SUM(COALESCE(d."forecastSales", 0)) > 0
            THEN ROUND(
                (SUM(COALESCE(d."forecastTradeMargin$", 0)) / SUM(COALESCE(d."forecastSales", 0))) * 100,
            2)
            ELSE 0
        END AS "forecastTradeMargin%",
		-- Units and incremental
        SUM(COALESCE(d."everydayUnits", 0))                      AS "everydayUnits",
        SUM(COALESCE(d."categoryforecast", 0))                   AS "forecastUnits",
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)        AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)         AS "incrementalSales$",

        -- Scan support
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        ROUND(SUM((COALESCE(d."LatestEffectiveCost", 0) * (COALESCE(d."scanSupport%", 0)/100) * COALESCE(d."categoryforecast", 0))),2) AS "totalScanSupport%"
    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"
    WHERE  (o."OfferTypeId" IN (14))
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
        AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId",   d."offerNo"
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

    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForStdRangePrice s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";

  WITH EventOfferDtlSummaryforAdvPriceForStdRangePrice AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,
		 d."clearanceIndicator",
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
        AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId",  d."clearanceIndicator", d."offerNo"
)
UPDATE public."tEventOffer" AS o
SET
    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2),
    "everydayPriceGst"      = ROUND(s."everydayPrice", 2),
	"everydayPrice"         = ROUND(s."everydayPrice" / (1 + s.gst_value), 2),
    "savePercent" = ROUND(s."savePercent", 2)
	FROM EventOfferDtlSummaryforAdvPriceForStdRangePrice s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";
	END IF;
	
		IF p_offer_type_id = 25 THEN

	-- COMBO SKU LIST & STD RANGE PRICE
WITH EventOfferDtlSummaryForComboList AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,
        -- Forecast metrics
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)             AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)            AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)     AS "forecastTradeMargin$",
        CASE
            WHEN SUM(COALESCE(d."forecastSales", 0)) > 0
            THEN ROUND(
                (SUM(COALESCE(d."forecastTradeMargin$", 0)) / SUM(COALESCE(d."forecastSales", 0))) * 100,
            2)
            ELSE 0
        END AS "forecastTradeMargin%",
        -- Units and incremental
        SUM(COALESCE(d."everydayUnits", 0))                      AS "everydayUnits",
        SUM(COALESCE(d."categoryforecast", 0))                   AS "forecastUnits",
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)        AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)         AS "incrementalSales$",

        -- Scan support
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        ROUND(SUM((COALESCE(d."LatestEffectiveCost", 0) * (COALESCE(d."scanSupport%", 0)/100) * COALESCE(d."categoryforecast", 0))),2) AS "totalScanSupport%"
		   
    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"
    WHERE  (o."OfferTypeId" IN (25))
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
        AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId",   d."offerNo"
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
    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" 
FROM EventOfferDtlSummaryForComboList s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";

  	-- COMBO SKU LIST 
WITH EventOfferDtlSummaryForAdvPriceForComboList AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
		d."clearanceIndicator",
        v_gst AS gst_value,
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
	  AND (d."clearanceIndicator" <> 'Y' OR d."clearanceIndicator" IS NULL)
	  AND d."offerId" = p_offer_id
        AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId",   d."clearanceIndicator",d."offerNo"
)
UPDATE public."tEventOffer" AS o
SET

    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2),
    "everydayPriceGst"      = ROUND(s."everydayPrice", 2),
	"everydayPrice"         = ROUND(s."everydayPrice" / (1 + s.gst_value), 2),
    "savePercent" = ROUND(s."savePercent", 2)
FROM EventOfferDtlSummaryForAdvPriceForComboList s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";
	END IF;
	
	IF p_offer_type_id = 15 THEN
	
	  WITH EventOfferDtlSummaryForMultiBuySKUList AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,

        -- Forecast metrics
		ROUND(SUM(COALESCE(d."purchaseQuantity")),2) 			 AS "purchaseQuantity",
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)             AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)            AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)     AS "forecastTradeMargin$",
        CASE
            WHEN SUM(COALESCE(d."forecastSales", 0)) > 0
            THEN ROUND(
                (SUM(COALESCE(d."forecastTradeMargin$", 0)) / SUM(COALESCE(d."forecastSales", 0))) * 100,
            2)
            ELSE 0
        END AS "forecastTradeMargin%",
        -- Units and incremental
        SUM(COALESCE(d."everydayUnits", 0))                      AS "everydayUnits",
        SUM(COALESCE(d."categoryforecast", 0))                   AS "forecastUnits",
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)        AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)         AS "incrementalSales$",

        -- Scan support
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        ROUND(SUM((COALESCE(d."LatestEffectiveCost", 0) * (COALESCE(d."scanSupport%", 0)/100) * COALESCE(d."categoryforecast", 0))),2) AS "totalScanSupport%"
		   
    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"
		
    WHERE  (o."OfferTypeId" IN (15))
	  AND d."offerNo" = p_offer_no
	  AND d."offerId" = p_offer_id
         AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId", d."offerNo"
)
UPDATE public."tEventOffer" AS o
SET
    -- Forecast metrics
	"purchaseQuantity"		= s."purchaseQuantity",
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
    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForMultiBuySKUList s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";

  	  WITH EventOfferDtlSummaryForAdvPriceForMultiBuySKUList AS (
    SELECT
        d."offerId",
        d."eventId",
		d."offerNo",
        v_gst AS gst_value,
		d."clearanceIndicator",
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
        AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId", d."clearanceIndicator", d."offerNo"
)
UPDATE public."tEventOffer" AS o
SET
  

    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
        "saveValue"             = ROUND(s."saveValue", 2)* o."requiredQuantity",
    "everydayPriceGst"      = ROUND(s."everydayPrice", 2),
	"everydayPrice"         = ROUND(s."everydayPrice" / (1 + s.gst_value), 2),
    "calculatedSavePercent" = ROUND(s."savePercent", 2)
	
FROM EventOfferDtlSummaryForAdvPriceForMultiBuySKUList s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";
END IF;

	IF p_offer_type_id = 23 THEN
	

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
        ROUND(SUM((COALESCE(d."LatestEffectiveCost", 0) * (COALESCE(d."scanSupport%", 0)/100) * COALESCE(d."categoryforecast", 0))),2) AS "totalScanSupport%",
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
        AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId", d."offerNo"
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
	"everydayPrice"         = ROUND(s."everydayPrice" / (1 + s.gst_value), 2),

    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForPriceOnlySKUList s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
  AND o."offerNumber" = s."offerNo";

  
END IF;
END;
$BODY$;