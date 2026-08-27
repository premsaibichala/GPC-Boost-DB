-- PROCEDURE: public.sp_update_event_offer_detailslppobxgx()

-- DROP PROCEDURE IF EXISTS public.sp_update_event_offer_detailslppobxgx();

CREATE OR REPLACE PROCEDURE public.sp_update_event_offer_detailslppobxgx(
	)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_start_time timestamptz;
    v_end_time   timestamptz;
    v_log_id     bigint;
    v_job_name   text := 'sp_update_event_offer_detailsLPPOBXGX';
BEGIN
    -- Force this procedure to use AEST (Australia/Sydney)
    SET LOCAL TIME ZONE 'Australia/Sydney';

    -- Get start time in AEST and insert STARTED log row
    v_start_time := clock_timestamp();

    INSERT INTO execution_log (job_name, status, start_time)
    VALUES (v_job_name, 'STARTED', v_start_time)
    RETURNING id INTO v_log_id;

    -- ------------------------------------------------------------------
    -- PERF: materialise the price-list waterfall ONCE for this run.
    -- Previously every UPDATE recomputed pricelistDetail/pivoted_prices,
    -- each a full window-sort over tPriceListDetail. Build it a single
    -- time here, scoped to SKUs used by OPEN/LOCKED events, then index it.
    -- ------------------------------------------------------------------
    DROP TABLE IF EXISTS tmp_pivoted_prices_lppobxgx;
    CREATE TEMP TABLE tmp_pivoted_prices_lppobxgx AS
    WITH "relevantSkus" AS (
        SELECT DISTINCT eod."sku"
        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
        WHERE eh."status" IN ('Open', 'Locked')
          AND eoh."OfferTypeId" IN (1, 13, 17)
          AND eod."isSkuActive" = TRUE
    ),
    "pricelistDetail" AS (
        SELECT
            pld."sku",
            pld."priceList",
            pld."priceListPrice",
            pld."country",
            pld."company",
            ROW_NUMBER() OVER (
                PARTITION BY pld."sku", pld."country", pld."company",
                CASE
                    WHEN pld."priceList" = '050' THEN 'clearance'
                    WHEN pld."priceList" = '184' THEN 'special_184'
                    WHEN pld."priceList" = '499' THEN 'nz_clearance_499'
                    WHEN pld."priceList" = '498' THEN 'nz_special_498'
                    WHEN pld."priceList" IN ('390','419','824','343','446','241') THEN 'au_primary'
                    WHEN pld."priceList" = '036' THEN 'au_fallback'
                    WHEN pld."priceList" IN ('371','274','211','044','134','021') THEN 'nz_primary'
                    WHEN pld."priceList" = '492' THEN 'nz_fallback'
                END
                ORDER BY pld."startDate" DESC
            ) AS group_rn
        FROM "tPriceListDetail" pld
        INNER JOIN "tPriceList" pl ON pld."priceList" = pl."priceList"
        WHERE pld."priceList" IN ('050','184','499','498','390','419','824','343','446','241','036','371','274','211','044','134','021','492')
          AND pld."isActive"
          AND pld."sku" IN (SELECT "sku" FROM "relevantSkus")
    )
    SELECT
        t.*,
        CASE WHEN t."country" = 'AU' THEN LEAST(t.clearance_price_050, t.priceList184)
             WHEN t."country" = 'NZ' THEN LEAST(t.priceList499, t.priceList498) END AS special_price,
        t.au_primary_price AS au_primary,
        t.au_fallback_price_036 AS au_fallback_036,
        t.nz_primary_price AS nz_primary,
        t.nz_fallback_price_492 AS nz_fallback_492
    FROM (
        SELECT
            "sku","country","company",
            MAX(CASE WHEN "priceList" = '050' AND group_rn = 1 THEN "priceListPrice" END) AS clearance_price_050,
            MAX(CASE WHEN "priceList" = '184' AND group_rn = 1 THEN "priceListPrice" END) AS priceList184,
            MAX(CASE WHEN "priceList" = '499' AND group_rn = 1 THEN "priceListPrice" END) AS priceList499,
            MAX(CASE WHEN "priceList" = '498' AND group_rn = 1 THEN "priceListPrice" END) AS priceList498,
            MAX(CASE WHEN "priceList" IN ('390','419','824','343','446','241') AND group_rn = 1 THEN "priceListPrice" END) AS au_primary_price,
            MAX(CASE WHEN "priceList" = '036' AND group_rn = 1 THEN "priceListPrice" END) AS au_fallback_price_036,
            MAX(CASE WHEN "priceList" IN ('371','274','211','044','134','021') AND group_rn = 1 THEN "priceListPrice" END) AS nz_primary_price,
            MAX(CASE WHEN "priceList" = '492' AND group_rn = 1 THEN "priceListPrice" END) AS nz_fallback_price_492
        FROM "pricelistDetail"
        WHERE group_rn = 1
        GROUP BY "sku","country","company"
    ) t;

    CREATE INDEX ON tmp_pivoted_prices_lppobxgx ("sku","country","company");
    ANALYZE tmp_pivoted_prices_lppobxgx;
    RAISE NOTICE '[%] tmp_pivoted_prices_lppobxgx built', clock_timestamp();

    -- ------------------------------------------------------------------
    -- PERF: pre-aggregate tInventory by (sku, company) ONCE.
    -- ------------------------------------------------------------------
    DROP TABLE IF EXISTS tmp_inventory_soh_lppobxgx;
    CREATE TEMP TABLE tmp_inventory_soh_lppobxgx AS
    WITH "relevantSkuCompanies" AS (
        SELECT DISTINCT eod."sku", eh."company"
        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
        WHERE eh."status" IN ('Open', 'Locked')
          AND eoh."OfferTypeId" IN (1, 13, 17)
          AND eod."isSkuActive" = TRUE
    )
    SELECT
        rc."sku",
        rc."company",
        COALESCE(SUM(CASE WHEN UPPER(inv."locationType") = 'STORE' THEN inv."onHand" END), 0) AS "sohStore",
        COALESCE(SUM(CASE WHEN UPPER(inv."locationType") <> 'STORE' THEN inv."onHand" END), 0) AS "sohDc"
    FROM "relevantSkuCompanies" rc
    LEFT JOIN "tInventory" inv
        ON inv."sku" = rc."sku"
       AND inv."company" IN (rc."company", '12', '52')
    GROUP BY rc."sku", rc."company";

    CREATE INDEX ON tmp_inventory_soh_lppobxgx ("sku", "company");
    ANALYZE tmp_inventory_soh_lppobxgx;
    RAISE NOTICE '[%] tmp_inventory_soh_lppobxgx built - starting detail updates', clock_timestamp();


-- ===================================================================================================
-- UPDATE tEventOfferDetail For Line And Price
--===============================================================================================================

    -- LINE & PRICE
    RAISE NOTICE '[%] START UPDATE tEventOfferDetail | offerType=Line And Price | offerTypeId=1', clock_timestamp();
    WITH

       updateEventOfferDtlForLP AS (
        SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
            eoh."OfferTypeId",
            eoh."spacePurchase",
            p."clearance",
            rag."G0",
            rag."G1",
            rag."G2",
            rag."G3",
            rag."G4",
             rag."G5",
            (COALESCE(s."averageMonthlySales", 0) / 30.0) *
            ((COALESCE(eoh."endDate", eh."endDate") - COALESCE(eoh."startDate", eh."startDate")) + 1) AS calc_units,
            config."configvalue"->>'channel' AS "salesType",
            eod."gst" AS gst_value,
            ppr."pricePoint6",
            ppr."pricePoint6IncludingGst",
            p."vendorCostPerEach",
            p."nationalAvgCost",
            eoh."advertisedPriceGst",
            eh."country",

            COALESCE(inv."sohStore", 0) AS sohStore,
            COALESCE(inv."sohDc", 0) AS sohDc,

            pp.clearance_price_050,
            pp.priceList184,
            pp.au_primary_price,
            pp.au_fallback_price_036,
            pp.nz_primary_price,
            pp.nz_fallback_price_492,
            pp.special_price,
            pp.au_primary,
            pp.au_fallback_036,
            pp.nz_primary,
            pp.nz_fallback_492

        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
            INNER JOIN "tProducts" p
            ON p."sku" = eod."sku" and p."isActive"=true
         INNER JOIN "tPriceProductRules" ppr
            ON ppr."sku" = eod."sku"
            AND ppr."company" = eh."company"
            and ppr."startDate"<=CURRENT_DATE and  ppr."endDate">=CURRENT_DATE
            and ppr."isActive" = TRUE

        INNER JOIN "tConfig" config
            ON config."configkey" = eh."channel"
           AND config."country" = eh."country"
           AND config."configtype" = 'SalesType'
        LEFT JOIN tmp_pivoted_prices_lppobxgx pp ON pp."sku" = eod."sku" AND pp."country" = eh."country" AND pp."company" = eh."company"
        LEFT JOIN tmp_inventory_soh_lppobxgx inv
            ON inv."sku" = eod."sku"
            AND inv."company" = eh."company"
         LEFT JOIN "tSalesY1" s
            ON s."sku" = eod."sku"
           AND s."company" = eh."company"
           AND s."salesType" = config."configvalue" ->> 'channel'
        LEFT JOIN "tRegionalAreaGroupAllocation" rag
             on rag."allocationGroup"='DEFAULT'
             AND rag."country" = eh."country"
        WHERE eoh."OfferTypeId" = 1
        AND eh."status" IN ('Open', 'Locked')
    ),

    "baseRrpCalculation_LP" AS (
        SELECT
            d.*,
            CASE
                -- AC5: Clearance matches exclusively list 050 (inclusive of GST per AC6)
                WHEN d."country" = 'AU' THEN
                    COALESCE(
                        d.special_price,
                        d.au_primary,
                        d.au_fallback_036,
                        ROUND(
                            CASE
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 1 THEN
                                    CEILING((ROUND(d."pricePoint6IncludingGst", 2)) * 10) / 10.0
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 10 THEN
                                    CASE WHEN ((ROUND(d."pricePoint6IncludingGst", 2)) - FLOOR(ROUND(d."pricePoint6IncludingGst", 2))) > 0.5
                                         THEN CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                                         ELSE FLOOR(ROUND(d."pricePoint6IncludingGst", 2))
                                    END
                                ELSE CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                            END, 2
                        )
                    )
                WHEN d."country" = 'NZ' THEN
                    COALESCE(
                        d.special_price,
                        d.nz_primary,
                        d.nz_fallback_492,
                        ROUND(
                            CASE
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 1 THEN
                                    CEILING((ROUND(d."pricePoint6IncludingGst", 2)) * 10) / 10.0
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 10 THEN
                                    CASE WHEN ((ROUND(d."pricePoint6IncludingGst", 2)) - FLOOR(ROUND(d."pricePoint6IncludingGst", 2))) > 0.5
                                         THEN CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                                         ELSE FLOOR(ROUND(d."pricePoint6IncludingGst", 2))
                                    END
                                ELSE CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                            END, 2
                        )
                    )
                END AS base_rrp_price
        FROM updateEventOfferDtlForLP d
    ),

    calculationsForEventOfferDtlLP AS (
        SELECT
            d.*,
            d.base_rrp_price AS new_everydayPriceGst,
            CASE WHEN d."clearance" = 'Y' THEN d.base_rrp_price
                 ELSE ROUND(d."advertisedPriceGst",2)
            END AS new_advertisedPriceGst,
            CASE WHEN d."clearance" = 'Y' THEN ROUND(d.base_rrp_price / (1 + COALESCE(d.gst_value, 0)),2)
                 ELSE ROUND(d."advertisedPriceGst" / (1 + COALESCE(d.gst_value, 0)),2)
            END AS new_advertisedPrice,
            ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM "baseRrpCalculation_LP" d
    )
    --- LINE & PRICE
    UPDATE "tEventOfferDetail" e
    SET
        "everydayUnits" = ROUND(c.calc_units),
        "everydayPrice" = Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2),
        "everydayPriceGst" = c.new_everydayPriceGst,
        "everydayPriceGstSys" = c.new_everydayPriceGst,
        "clearanceIndicator" = CASE WHEN c."clearance" IS NULL OR TRIM(c."clearance") = '' THEN 'N' ELSE c."clearance" END,
        "advertisedPriceGst" = c.new_advertisedPriceGst,
        "advertisedPrice" = c.new_advertisedPrice,
         "calculatedSaveValue"=Round(c.new_everydayPriceGst-c.new_advertisedPriceGst,2),
        "calculatedSavePercentage" = CASE
    WHEN c.new_everydayPriceGst > 0 THEN ROUND(((c.new_everydayPriceGst - c.new_advertisedPriceGst) / c.new_everydayPriceGst) * 100, 2)
    ELSE 0
END,
        "incrementalForecast"=e."categoryforecast"-ROUND(c.calc_units),
        "nationalAverageCost" = COALESCE(c.natAvgCost, 0),
         "forecastTradeMargin$" = ROUND((c.new_advertisedPrice - ROUND(COALESCE(c."vendorCostPerEach",0),2)) * e."categoryforecast",2),
        "stockOnHandStore" = c.sohStore,
        "stockOnHandDC"    = c.sohDc,
        "LatestEffectiveCost" = ROUND(COALESCE(c."vendorCostPerEach",0),2),
        "categoryCost"        = COALESCE(c.natAvgCost, 0),
          "forecastCost"=Round(ROUND(COALESCE(c."vendorCostPerEach",0),2)*e."categoryforecast",2),
        "forecastSales"=Round(e."categoryforecast"*ROUND(c.new_advertisedPriceGst,2),2),
        "everydayExtendedUnitCost"  = ROUND(c.calc_units )* COALESCE(c.natAvgCost, 0),
        "everydayExtendedUnitSales" = ROUND(c.calc_units )* c.new_everydayPriceGst,

        "extendedAdvertisedPrice" = ROUND(c.calc_units) * COALESCE(c.new_advertisedPriceGst, 0),
         "everydayCost" = COALESCE(c.natAvgCost, 0),

       "incrementalSales"=Round(Round(e."categoryforecast"*ROUND(c.new_advertisedPriceGst,2),2) - (ROUND(c.calc_units)*c.new_everydayPriceGst),2),
        "incrementalTrade$" =  ROUND( ROUND((c.new_advertisedPrice - ROUND(COALESCE(c."vendorCostPerEach",0),2)) * e."categoryforecast",2) - ROUND((Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2)-ROUND(COALESCE(c."vendorCostPerEach",0),2) )*ROUND(c.calc_units),2), 2),
        "forecastTradeMargin%" = CASE
        WHEN Round(e."categoryforecast"*ROUND(c.new_advertisedPrice,2),2) > 0
        THEN
               ROUND(((c.new_advertisedPrice - ROUND(COALESCE(c."vendorCostPerEach",0),2)) * e."categoryforecast") / (e."categoryforecast" * c.new_advertisedPrice) * 100, 2)

        ELSE 0
        END,
        "totalTieUp" =
        (COALESCE(e."group0Quantity",0) * COALESCE(c."G0",0)) +
        (COALESCE(e."group1Quantity",0) * COALESCE(c."G1",0)) +
        (COALESCE(e."group2Quantity",0) * COALESCE(c."G2",0)) +
        (COALESCE(e."group3Quantity",0) * COALESCE(c."G3",0)) +
        (COALESCE(e."group4Quantity",0) * COALESCE(c."G4",0)) +
        (COALESCE(e."group5Quantity",0) * COALESCE(c."G5",0)),
    "tieUpCost" = ROUND(
        ((COALESCE(e."group0Quantity",0) * COALESCE(c."G0",0)) +
         (COALESCE(e."group1Quantity",0) * COALESCE(c."G1",0)) +
         (COALESCE(e."group2Quantity",0) * COALESCE(c."G2",0)) +
         (COALESCE(e."group3Quantity",0) * COALESCE(c."G3",0)) +
         (COALESCE(e."group4Quantity",0) * COALESCE(c."G4",0)) +
         (COALESCE(e."group5Quantity",0) * COALESCE(c."G5",0)))
         * ROUND(COALESCE(c."vendorCostPerEach",0),2),
    2)
    FROM calculationsForEventOfferDtlLP c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId"=1;
    RAISE NOTICE '[%] END   UPDATE tEventOfferDetail | offerType=Line And Price | offerTypeId=1', clock_timestamp();

-- ===================================================================================================
-- UPDATE tEventOfferDetail For Price Only
--===============================================================================================================

-- PRICE ONLY
 RAISE NOTICE '[%] START UPDATE tEventOfferDetail | offerType=Price Only | offerTypeId=13', clock_timestamp();
 WITH

      updateEventOfferDtlForPriceOnly AS (
        SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
            eoh."OfferTypeId",
            p."clearance",
            eoh."spacePurchase",
            rag."G0",
            rag."G1",
            rag."G2",
            rag."G3",
            rag."G4",
             rag."G5",
            (COALESCE(s."averageMonthlySales", 0) / 30.0) *
            ((COALESCE(eoh."endDate", eh."endDate") - COALESCE(eoh."startDate", eh."startDate")) + 1) AS calc_units,
            config."configvalue"->>'channel' AS "salesType",
            eod."gst" AS gst_value,
            ppr."pricePoint6",
            ppr."pricePoint6IncludingGst",
            p."vendorCostPerEach",
            p."nationalAvgCost",
            eh."country",
            COALESCE(inv."sohStore", 0) AS sohStore,
            COALESCE(inv."sohDc", 0) AS sohDc,

            pp.clearance_price_050,
            pp.priceList184,
            pp.au_primary_price,
            pp.au_fallback_price_036,
            pp.nz_primary_price,
            pp.nz_fallback_price_492,
            pp.special_price,
            pp.au_primary,
            pp.au_fallback_036,
            pp.nz_primary,
            pp.nz_fallback_492

        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
            INNER JOIN "tProducts" p
            ON p."sku" = eod."sku" and p."isActive"=true
        INNER JOIN "tPriceProductRules" ppr
            ON ppr."sku" = eod."sku"
            AND ppr."company" = eh."company"
            and ppr."startDate"<=CURRENT_DATE and  ppr."endDate">=CURRENT_DATE
            and ppr."isActive" = TRUE

        INNER JOIN "tConfig" config
            ON config."configkey" = eh."channel"
           AND config."country" = eh."country"
           AND config."configtype" = 'SalesType'
        LEFT JOIN tmp_pivoted_prices_lppobxgx pp ON pp."sku" = eod."sku" AND pp."country" = eh."country" AND pp."company" = eh."company"
         LEFT JOIN tmp_inventory_soh_lppobxgx inv
            ON inv."sku" = eod."sku"
            AND inv."company" = eh."company"
         LEFT JOIN "tSalesY1" s
            ON s."sku" = eod."sku"
           AND s."company" = eh."company"
           AND s."salesType" = config."configvalue" ->> 'channel'
        LEFT JOIN "tRegionalAreaGroupAllocation" rag
             on rag."allocationGroup"='DEFAULT'
             AND rag."country" = eh."country"
        WHERE eoh."OfferTypeId" = 13
        AND eh."status" IN ('Open', 'Locked')
    ),

    "baseRrpCalculation_PO" AS (
        SELECT
            d.*,
            CASE
                WHEN d."country" = 'AU' THEN
                    COALESCE(
                        d.special_price,
                        d.au_primary,
                        d.au_fallback_036,
                        ROUND(
                            CASE
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 1 THEN
                                    CEILING((ROUND(d."pricePoint6IncludingGst", 2)) * 10) / 10.0
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 10 THEN
                                    CASE WHEN ((ROUND(d."pricePoint6IncludingGst", 2)) - FLOOR(ROUND(d."pricePoint6IncludingGst", 2))) > 0.5
                                         THEN CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                                         ELSE FLOOR(ROUND(d."pricePoint6IncludingGst", 2))
                                    END
                                ELSE CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                            END, 2
                        )
                    )
                WHEN d."country" = 'NZ' THEN
                    COALESCE(
                        d.special_price,
                        d.nz_primary,
                        d.nz_fallback_492,
                        ROUND(
                            CASE
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 1 THEN
                                    CEILING((ROUND(d."pricePoint6IncludingGst", 2)) * 10) / 10.0
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 10 THEN
                                    CASE WHEN ((ROUND(d."pricePoint6IncludingGst", 2)) - FLOOR(ROUND(d."pricePoint6IncludingGst", 2))) > 0.5
                                         THEN CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                                         ELSE FLOOR(ROUND(d."pricePoint6IncludingGst", 2))
                                    END
                                ELSE CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                            END, 2
                        )
                    )
                END AS base_rrp_price
        FROM updateEventOfferDtlForPriceOnly d
    ),

    calculationsForEventOfferDtlPriceOnly AS (
        SELECT
            d.*,
            d.base_rrp_price AS new_everydayPriceGst,
            ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM "baseRrpCalculation_PO" d
    )
    --Price Only (SKU LISt)
    UPDATE "tEventOfferDetail" e
    SET
        "everydayUnits" = ROUND(c.calc_units),
        "everydayPrice" = Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2),
        "everydayPriceGst" = c.new_everydayPriceGst,
        "advertisedPriceGst" = c.new_everydayPriceGst,
        "clearanceIndicator" = CASE WHEN c."clearance" IS NULL OR TRIM(c."clearance") = '' THEN 'N' ELSE c."clearance" END,
        "advertisedPrice" = Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2),
        "everydayPriceGstSys" = c.new_everydayPriceGst,
        "calculatedSaveValue"=0,
        "calculatedSavePercentage" = 0,
        "forecastCost"=Round(ROUND(COALESCE(c."vendorCostPerEach",0),2)*e."categoryforecast",2),
        "forecastSales"=Round(e."categoryforecast"*ROUND(c.new_everydayPriceGst,2),2),
        "incrementalForecast"=e."categoryforecast"-ROUND(c.calc_units),
        "nationalAverageCost" = COALESCE(c.natAvgCost, 0),
        "forecastTradeMargin$" = ROUND((Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2)- ROUND(COALESCE(c."vendorCostPerEach",0),2)) * e."categoryforecast",2),
        "stockOnHandStore" = c.sohStore,
        "stockOnHandDC"    = c.sohDc,
        "LatestEffectiveCost" = ROUND(COALESCE(c."vendorCostPerEach",0),2),
        "categoryCost"        = COALESCE(c.natAvgCost, 0),

        "everydayExtendedUnitCost"  = ROUND(c.calc_units )* COALESCE(c.natAvgCost, 0),
        "everydayExtendedUnitSales" = ROUND(c.calc_units )* c.new_everydayPriceGst,

        "extendedAdvertisedPrice" = ROUND(c.calc_units )* COALESCE(c.new_everydayPriceGst, 0),
        "everydayCost" = COALESCE(c.natAvgCost, 0),
        "incrementalSales"=Round(Round(e."categoryforecast"*ROUND(c.new_everydayPriceGst,2),2) - (ROUND(c.calc_units)*c.new_everydayPriceGst),2),
        "incrementalTrade$" =  ROUND( ROUND((Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2) - ROUND(COALESCE(c."vendorCostPerEach",0),2)) * e."categoryforecast",2) - ROUND((Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2)-ROUND(COALESCE(c."vendorCostPerEach",0),2) )*ROUND(c.calc_units),2), 2),
        "forecastTradeMargin%" = CASE
        WHEN Round(e."categoryforecast"*Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2),2) > 0
        THEN
               ROUND(((c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)) - ROUND(COALESCE(c."vendorCostPerEach",0),2)) * e."categoryforecast") / (e."categoryforecast" * Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2))*100, 2)

        ELSE 0
        END,
        "totalTieUp" =
        (COALESCE(e."group0Quantity",0) * COALESCE(c."G0",0)) +
        (COALESCE(e."group1Quantity",0) * COALESCE(c."G1",0)) +
        (COALESCE(e."group2Quantity",0) * COALESCE(c."G2",0)) +
        (COALESCE(e."group3Quantity",0) * COALESCE(c."G3",0)) +
        (COALESCE(e."group4Quantity",0) * COALESCE(c."G4",0)) +
        (COALESCE(e."group5Quantity",0) * COALESCE(c."G5",0)),
    "tieUpCost" = ROUND(
        ((COALESCE(e."group0Quantity",0) * COALESCE(c."G0",0)) +
         (COALESCE(e."group1Quantity",0) * COALESCE(c."G1",0)) +
         (COALESCE(e."group2Quantity",0) * COALESCE(c."G2",0)) +
         (COALESCE(e."group3Quantity",0) * COALESCE(c."G3",0)) +
         (COALESCE(e."group4Quantity",0) * COALESCE(c."G4",0)) +
         (COALESCE(e."group5Quantity",0) * COALESCE(c."G5",0)))
         * ROUND(COALESCE(c."vendorCostPerEach",0),2),
    2)
    FROM calculationsForEventOfferDtlPriceOnly c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId"=13;
    RAISE NOTICE '[%] END   UPDATE tEventOfferDetail | offerType=Price Only | offerTypeId=13', clock_timestamp();

-- ===================================================================================================
-- UPDATE tEventOfferDetail For BXGX
--===============================================================================================================

--updateEventOfferDtl_BXGX
    RAISE NOTICE '[%] START UPDATE tEventOfferDetail | offerType=BXGX | offerTypeId=17', clock_timestamp();
    WITH

      updateEventOfferDtlForBXGX AS (
        SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
            eoh."OfferTypeId",
            p."clearance",
            rag."G0",
            rag."G1",
            rag."G2",
            rag."G3",
            rag."G4",
             rag."G5",
             eoh."spacePurchase",
            (COALESCE(s."averageMonthlySales", 0) / 30.0) *
            ((COALESCE(eoh."endDate", eh."endDate") - COALESCE(eoh."startDate", eh."startDate")) + 1) AS calc_units,
            config."configvalue"->>'channel' AS "salesType",
            eod."gst" AS gst_value,
            ppr."pricePoint6",
            ppr."pricePoint6IncludingGst",
            p."vendorCostPerEach",
            p."nationalAvgCost",
            eoh."advertisedPriceGst",
            eh."country",
            COALESCE(inv."sohStore", 0) AS sohStore,
            COALESCE(inv."sohDc", 0) AS sohDc,

            pp.clearance_price_050,
            pp.priceList184,
            pp.au_primary_price,
            pp.au_fallback_price_036,
            pp.nz_primary_price,
            pp.nz_fallback_price_492,
            pp.special_price,
            pp.au_primary,
            pp.au_fallback_036,
            pp.nz_primary,
            pp.nz_fallback_492

        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
             INNER JOIN "tProducts" p
            ON p."sku" = eod."sku" and p."isActive"=true
       INNER JOIN "tPriceProductRules" ppr
            ON ppr."sku" = eod."sku"
            AND ppr."company" = eh."company"
            and ppr."startDate"<=CURRENT_DATE and  ppr."endDate">=CURRENT_DATE
            and ppr."isActive" = TRUE

        INNER JOIN "tConfig" config
            ON config."configkey" = eh."channel"
           AND config."country" = eh."country"
           AND config."configtype" = 'SalesType'
        LEFT JOIN tmp_pivoted_prices_lppobxgx pp ON pp."sku" = eod."sku" AND pp."country" = eh."country" AND pp."company" = eh."company"
         LEFT JOIN tmp_inventory_soh_lppobxgx inv
            ON inv."sku" = eod."sku"
            AND inv."company" = eh."company"
        LEFT JOIN "tSalesY1" s
            ON s."sku" = eod."sku"
           AND s."company" = eh."company"
           AND s."salesType" = config."configvalue" ->> 'channel'
        LEFT JOIN "tRegionalAreaGroupAllocation" rag
             on rag."allocationGroup"='DEFAULT'
             AND rag."country" = eh."country"
        WHERE eoh."OfferTypeId" IN (17)
        AND eh."status" IN ('Open', 'Locked')
    ),

    "baseRrpCalculation_BXGX" AS (
        SELECT
            d.*,
            CASE
                WHEN d."country" = 'AU' THEN
                    COALESCE(
                        d.special_price,
                        d.au_primary,
                        d.au_fallback_036,
                        ROUND(
                            CASE
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 1 THEN
                                    CEILING((ROUND(d."pricePoint6IncludingGst", 2)) * 10) / 10.0
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 10 THEN
                                    CASE WHEN ((ROUND(d."pricePoint6IncludingGst", 2)) - FLOOR(ROUND(d."pricePoint6IncludingGst", 2))) > 0.5
                                         THEN CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                                         ELSE FLOOR(ROUND(d."pricePoint6IncludingGst", 2))
                                    END
                                ELSE CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                            END, 2
                        )
                    )
                WHEN d."country" = 'NZ' THEN
                    COALESCE(
                        d.special_price,
                        d.nz_primary,
                        d.nz_fallback_492,
                        ROUND(
                            CASE
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 1 THEN
                                    CEILING((ROUND(d."pricePoint6IncludingGst", 2)) * 10) / 10.0
                                WHEN (ROUND(d."pricePoint6IncludingGst", 2)) < 10 THEN
                                    CASE WHEN ((ROUND(d."pricePoint6IncludingGst", 2)) - FLOOR(ROUND(d."pricePoint6IncludingGst", 2))) > 0.5
                                         THEN CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                                         ELSE FLOOR(ROUND(d."pricePoint6IncludingGst", 2))
                                    END
                                ELSE CEILING(ROUND(d."pricePoint6IncludingGst", 2))
                            END, 2
                        )
                    )
                END AS base_rrp_price
        FROM updateEventOfferDtlForBXGX d
    ),

    calculationsForEventOfferDtlBXGX AS (
        SELECT
            d.*,
            d.base_rrp_price AS new_everydayPriceGst,
            CASE WHEN d."clearance" = 'Y' THEN d.base_rrp_price
                 ELSE ROUND(d."advertisedPriceGst",2)
            END AS new_advertisedPriceGst,
            CASE WHEN d."clearance" = 'Y' THEN ROUND(d.base_rrp_price / (1 + COALESCE(d.gst_value, 0)),2)
                 ELSE ROUND(d."advertisedPriceGst" / (1 + COALESCE(d.gst_value, 0)),2)
            END AS new_advertisedPrice,
            ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM "baseRrpCalculation_BXGX" d
    )
    UPDATE "tEventOfferDetail" e
    SET
        "everydayUnits" = ROUND(c.calc_units),
        "everydayPrice" = Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2),
        "everydayPriceGst" = c.new_everydayPriceGst,
        "everydayPriceGstSys" = c.new_everydayPriceGst,
        "advertisedPriceGst" = c.new_advertisedPriceGst,
        "advertisedPrice" =c.new_advertisedPrice,
        "calculatedSaveValue"= Round(c.new_everydayPriceGst-c.new_advertisedPriceGst,2),
        "calculatedSavePercentage" = CASE
    WHEN c.new_everydayPriceGst > 0 THEN ROUND(((c.new_everydayPriceGst - c.new_advertisedPriceGst) / c.new_everydayPriceGst) * 100, 2)
    ELSE 0
END,
        "incrementalForecast"=e."categoryforecast"-ROUND(c.calc_units),
        "nationalAverageCost" = COALESCE(c.natAvgCost, 0),
         "forecastTradeMargin$" = ROUND((c.new_advertisedPrice - ROUND(COALESCE(c."vendorCostPerEach",0),2)) * e."categoryforecast",2),
        "clearanceIndicator" = CASE WHEN c."clearance" IS NULL OR TRIM(c."clearance") = '' THEN 'N' ELSE c."clearance" END,
        "stockOnHandStore" = c.sohStore,
        "stockOnHandDC"    = c.sohDc,
        "LatestEffectiveCost" = ROUND(COALESCE(c."vendorCostPerEach",0),2),
        "categoryCost"        = COALESCE(c.natAvgCost, 0),
        "forecastCost"=Round(ROUND(COALESCE(c."vendorCostPerEach",0),2)*e."categoryforecast",2),
        "forecastSales"=Round(e."categoryforecast"*ROUND(c.new_advertisedPriceGst,2),2),
        "everydayExtendedUnitCost"  = ROUND(c.calc_units) * COALESCE(c.natAvgCost, 0),
        "everydayExtendedUnitSales" = ROUND(c.calc_units )* c.new_everydayPriceGst,

        "extendedAdvertisedPrice" = ROUND(c.calc_units )* COALESCE( c.new_advertisedPriceGst, 0),
        "everydayCost" = COALESCE(c.natAvgCost, 0),
        "incrementalSales"=Round(Round(e."categoryforecast"*ROUND(c.new_advertisedPriceGst,2),2) - (ROUND(c.calc_units)*c.new_everydayPriceGst),2),
        "incrementalTrade$" =  ROUND( ROUND((c.new_advertisedPrice - ROUND(COALESCE(c."vendorCostPerEach",0),2)) * e."categoryforecast",2) - ROUND((Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2)-ROUND(COALESCE(c."vendorCostPerEach",0),2) )*ROUND(c.calc_units),2), 2),
        "forecastTradeMargin%" = CASE
        WHEN Round(e."categoryforecast"*ROUND(c.new_advertisedPrice,2),2) > 0
        THEN
               ROUND(((c.new_advertisedPrice - ROUND(COALESCE(c."vendorCostPerEach",0),2)) * e."categoryforecast") / (e."categoryforecast" * c.new_advertisedPrice) * 100, 2)
        ELSE 0
        END,
        "totalTieUp" =
        (COALESCE(e."group0Quantity",0) * COALESCE(c."G0",0)) +
        (COALESCE(e."group1Quantity",0) * COALESCE(c."G1",0)) +
        (COALESCE(e."group2Quantity",0) * COALESCE(c."G2",0)) +
        (COALESCE(e."group3Quantity",0) * COALESCE(c."G3",0)) +
        (COALESCE(e."group4Quantity",0) * COALESCE(c."G4",0)) +
        (COALESCE(e."group5Quantity",0) * COALESCE(c."G5",0)),
    "tieUpCost" = ROUND(
        ((COALESCE(e."group0Quantity",0) * COALESCE(c."G0",0)) +
         (COALESCE(e."group1Quantity",0) * COALESCE(c."G1",0)) +
         (COALESCE(e."group2Quantity",0) * COALESCE(c."G2",0)) +
         (COALESCE(e."group3Quantity",0) * COALESCE(c."G3",0)) +
         (COALESCE(e."group4Quantity",0) * COALESCE(c."G4",0)) +
         (COALESCE(e."group5Quantity",0) * COALESCE(c."G5",0)))
         * ROUND(COALESCE(c."vendorCostPerEach",0),2),
    2)
    FROM calculationsForEventOfferDtlBXGX c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId" IN (17);
    RAISE NOTICE '[%] END   UPDATE tEventOfferDetail | offerType=BXGX | offerTypeId=17', clock_timestamp();

--===============================================================================================================
-- UPDATE tEventOffer For Line and Price & BXGX
--===============================================================================================================

--updateEventOfferDtlLP_BXGX
RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=Line & Price + BXGX | offerTypeId=1,17', clock_timestamp();
WITH EventOfferDtlSummaryForLP_BXGX AS (
    SELECT
        d."offerId",
        d."eventId",
        d."clearanceIndicator",
        d."gst" AS gst_value,
        -- Summed forecast values
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)              AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)             AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)      AS "forecastTradeMargin$",
        CASE
            WHEN SUM(COALESCE(d."forecastSales", 0)) > 0
            THEN ROUND(
                (SUM(COALESCE(d."forecastTradeMargin$", 0)) / (SUM(COALESCE(d."forecastSales", 0))/(1+d."gst"))) * 100,
            2)
            ELSE 0
        END AS "forecastTradeMargin%",
        ROUND(SUM(COALESCE(d."incrementalTrade$", 0)), 2)         AS "incrementalTm$",
        ROUND(SUM(COALESCE(d."incrementalSales", 0)), 2)          AS "incrementalSales$",

        -- Units and forecast
        SUM(COALESCE(d."categoryforecast", 0))                   AS "forecastUnits",
        SUM(COALESCE(d."everydayUnits", 0))                       AS "everydayUnits",
        SUM(COALESCE(d."scanSupport$", 0) * COALESCE(d."categoryforecast", 0)) AS "totalScanSupport$",
        ROUND(SUM((COALESCE(d."LatestEffectiveCost", 0) * (COALESCE(d."scanSupport%", 0)/100) * COALESCE(d."categoryforecast", 0))),2) AS "totalScanSupport%",
        -- Pricing
        MIN(d."everydayPrice")                       AS "everydayPrice",
        MIN(d."everydayPriceGst")                       AS "everydayPriceGst",
        SUM(COALESCE(d."advertisedPriceGst", 0))                  AS "advPrice",
        SUM(COALESCE(d."calculatedSaveValue", 0))                 AS "saveValue",
        SUM(COALESCE(d."calculatedSavePercentage", 0))                 AS "savePercent"

    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."eventId" = o."eventId"
    INNER JOIN public."tEvent" ev
        ON o."eventId" = ev."eventId"

    WHERE ev."status" IN ('Open', 'Locked')
      AND (o."OfferTypeId" IN (1,17))
      AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId",d."clearanceIndicator",d."gst"
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
    "incrementalTm$"        = s."incrementalTm$",
    "incrementalSales$"     = s."incrementalSales$",
    "incrementalUnits"      = CAST((s."forecastUnits" - s."everydayUnits") AS int),
    "totalScanSupport%"     = s."totalScanSupport%",

    -- Price + savings
    "advertisedPrice"       = ROUND(s."advPrice" / (1 + s.gst_value), 2),
    "advertisedPriceGst"    = ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2),
    "everydayPriceGst"      = ROUND(s."everydayPriceGst", 2),
    "everydayPrice"      = ROUND(s."everydayPrice", 2),
    "savePercent" = ROUND(s."savePercent", 2),
    "isClearance" = CASE WHEN s."clearanceIndicator" = 'Y' THEN true ELSE false END,
    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForLP_BXGX s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId"
 ;
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=Line & Price + BXGX | offerTypeId=1,17', clock_timestamp();

--===============================================================================================================
-- UPDATE tEventOffer For Price Only
--===============================================================================================================

  RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=Price Only | offerTypeId=13', clock_timestamp();
  WITH EventOfferDtlSummaryForPriceOnly AS (
    SELECT
        d."offerId",
        d."eventId",
        d."clearanceIndicator",
        d."gst" AS gst_value,
        -- Summed forecast values
        ROUND(SUM(COALESCE(d."forecastCost", 0)), 2)              AS "forecastCost",
        ROUND(SUM(COALESCE(d."forecastSales", 0)), 2)             AS "forecastSales",
        ROUND(SUM(COALESCE(d."forecastTradeMargin$", 0)), 2)      AS "forecastTradeMargin$",
        CASE
            WHEN SUM(COALESCE(d."forecastSales", 0)) > 0
            THEN ROUND(
                (SUM(COALESCE(d."forecastTradeMargin$", 0)) / (SUM(COALESCE(d."forecastSales", 0))/(1+d."gst"))) * 100,
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
        MIN(d."everydayPrice")                       AS "everydayPrice",
        MIN(d."everydayPriceGst")                       AS "everydayPriceGst",
        MAX(d."advertisedPriceGst")                  AS "advPrice",
        SUM(COALESCE(d."calculatedSaveValue", 0))                 AS "saveValue",
        SUM(COALESCE(d."calculatedSavePercentage", 0))                 AS "savePercent"

    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."eventId" = o."eventId"
    INNER JOIN public."tEvent" ev
        ON o."eventId" = ev."eventId"

    WHERE ev."status" IN ('Open', 'Locked')
      AND (o."OfferTypeId" IN (13))
      AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId",d."clearanceIndicator",d."gst"
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
    "everydayPriceGst"      = ROUND(s."everydayPriceGst", 2),
    "everydayPrice"      = ROUND(s."everydayPrice", 2),
    "savePercent" = ROUND(s."savePercent", 2),
    "isClearance" = CASE WHEN s."clearanceIndicator" = 'Y' THEN true ELSE false END,
    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForPriceOnly s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId";
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=Price Only | offerTypeId=13', clock_timestamp();

--===============================================================================================================
-- UPDATE tMudMapDetail For Line&Price PriceOnly and BXGX
--===============================================================================================================

RAISE NOTICE '[%] START UPDATE tMudMapDetail | offerType=Line&Price, Price Only & BXGX (Regular Offers) | offerTypeId=NOT IN (4,15,3,5)', clock_timestamp();
WITH RegularOffers AS (
    SELECT
        e."eventId",
        e."offerId",
        e."offerName",
        e."offerType",
        e."OfferTypeId",
        ev."status",
        ROUND(SUM(
            CASE
                WHEN COALESCE(e."advertisedPriceGst", 0) > 9999999 THEN 0
                ELSE COALESCE(e."advertisedPriceGst", 0)
            END
        ),2) AS "advertisedPrice",

        ROUND(SUM(
            CASE
                WHEN COALESCE(e."everydayPriceGst", 0) > 9999999 THEN 0
                ELSE COALESCE(e."everydayPriceGst", 0)
            END
        ),2) AS "everydayPriceGST",

        FLOOR(SUM(
            CASE
                WHEN COALESCE(e."saveValue", 0) > 9999999 THEN 0
                ELSE COALESCE(e."saveValue", 0)
            END
        )) AS "saveValue",

        CASE
            WHEN SUM(
                CASE
                    WHEN COALESCE(e."savePercent", 0) > 9999999 THEN 0
                    ELSE FLOOR(COALESCE(e."savePercent", 0))
                END
            ) < 5 THEN 0
            ELSE FLOOR(
                SUM(
                    CASE
                        WHEN COALESCE(e."savePercent", 0) > 9999999 THEN 0
                        ELSE FLOOR(COALESCE(e."savePercent", 0))
                    END
                ) / 5
            ) * 5
        END AS "savePercent",

        BOOL_OR(COALESCE(e."isClearance", FALSE)) AS clearance,
        BOOL_OR(COALESCE(e."isNew", FALSE)) AS new,
        BOOL_OR(COALESCE(e."isRewards", FALSE)) AS loyality,
        e."country",
        e."requiredQuantity" AS "RequiredQuantity",
        BOOL_OR(COALESCE(e."fromPrice", FALSE)) AS "fromPrice",
        e."purchaseQuantity" AS "PurchaseQuantity",
        e."freeQuantity" AS "FreeQuantity"
    FROM public."tEventOffer" AS e
    INNER JOIN public."tEvent" AS ev ON e."eventId" = ev."eventId"
    WHERE e."OfferTypeId" NOT IN (4,15)
      AND e."OfferTypeId" <> 3
      AND e."OfferTypeId" <> 5
      AND ev."status" IN ('Open', 'Locked')
    GROUP BY
        e."eventId", e."offerId", e."offerName", e."offerType", e."OfferTypeId",ev."status",
        e."country", e."requiredQuantity", e."fromPrice", e."purchaseQuantity", e."freeQuantity"
)
-- update tMudMapDetail RegularOffers
UPDATE public."tMudMapDetail" AS m
SET
    "offerName" = r."offerName",
    "offerType" = r."offerType",
    "offerTypeId" = r."OfferTypeId",
    "advertisedPrice" = r."advertisedPrice",
    "savePercent" = r."savePercent",
    "saveValue" = r."saveValue",
    "everydayPrice" = r."everydayPriceGST",
    clearance = r.clearance,
    new = r.new,
    loyality = r.loyality,
    "eventOfferId" = r."offerId",
    country = r.country,
    "requiredQuantity" = r."RequiredQuantity",
    "fromPrice" = r."fromPrice",
    "purchaseQuantity" = r."PurchaseQuantity",
    "freeQuantity" = r."FreeQuantity"
FROM RegularOffers AS r
WHERE m."eventId" = r."eventId"
  AND m."eventOfferId" = r."offerId"
 ;
RAISE NOTICE '[%] END   UPDATE tMudMapDetail | offerType=Line&Price, Price Only & BXGX (Regular Offers) | offerTypeId=NOT IN (4,15,3,5)', clock_timestamp();

   RAISE NOTICE 'Event offer details updated successfully for all SKUs.';

    v_end_time := clock_timestamp();

    UPDATE execution_log
    SET status      = 'SUCCESS',
        end_time    = v_end_time,
        duration_ms = (EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000)::bigint
    WHERE id = v_log_id;

EXCEPTION
    WHEN OTHERS THEN
        -- Log failure too
        v_end_time := clock_timestamp();

         RAISE LOG 'Daily_Refresh_Job_Failed';

        UPDATE execution_log
        SET status      = 'FAILED',
            end_time    = v_end_time,
            duration_ms = (EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000)::bigint
        WHERE id = v_log_id;

        RAISE;
END;
$BODY$;