-- PROCEDURE: public.sp_update_event_offer_detailspctstd()

-- DROP PROCEDURE IF EXISTS public.sp_update_event_offer_detailspctstd();

CREATE OR REPLACE PROCEDURE public.sp_update_event_offer_detailspctstd(
	)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_start_time timestamptz;
    v_end_time   timestamptz;
    v_log_id     bigint;
    v_job_name   text := 'sp_update_event_offer_detailsPCTSTD';
BEGIN
    -- Run in Australia/Sydney time
    SET LOCAL TIME ZONE 'Australia/Sydney';

    -- Start log
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
    DROP TABLE IF EXISTS tmp_pivoted_prices_pctstd;
    CREATE TEMP TABLE tmp_pivoted_prices_pctstd AS
    WITH "relevantSkus" AS (
        SELECT DISTINCT eod."sku"
        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
        WHERE eh."status" IN ('Open', 'Locked')
          AND eoh."OfferTypeId" IN (14, 6)
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

    CREATE INDEX ON tmp_pivoted_prices_pctstd ("sku","country","company");
    ANALYZE tmp_pivoted_prices_pctstd;
    RAISE NOTICE '[%] tmp_pivoted_prices_pctstd built', clock_timestamp();

    -- ------------------------------------------------------------------
    -- PERF: pre-aggregate tInventory by (sku, company) ONCE.
    -- ------------------------------------------------------------------
    DROP TABLE IF EXISTS tmp_inventory_soh_pctstd;
    CREATE TEMP TABLE tmp_inventory_soh_pctstd AS
    WITH "relevantSkuCompanies" AS (
        SELECT DISTINCT eod."sku", eh."company"
        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
        WHERE eh."status" IN ('Open', 'Locked')
          AND eoh."OfferTypeId" IN (14, 6)
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

    CREATE INDEX ON tmp_inventory_soh_pctstd ("sku", "company");
    ANALYZE tmp_inventory_soh_pctstd;
    RAISE NOTICE '[%] tmp_inventory_soh_pctstd built - starting detail updates', clock_timestamp();


-- ===================================================================================================
-- UPDATE tEventOfferDetail For STD Range Price
--===============================================================================================================

--STDRangePrice
RAISE NOTICE '[%] START UPDATE tEventOfferDetail | offerType=STD Range Price | offerTypeId=14', clock_timestamp();
WITH

  updateEventOfferDtlForSTDRangePrice AS (
      SELECT
          eod."sku",
          eod."offerNo",
          eod."offerId",
          eoh."offerType",
          eoh."OfferTypeId",
          p."clearance",
          rag."G0", rag."G1", rag."G2", rag."G3", rag."G4", rag."G5",
          (COALESCE(s."averageMonthlySales", 0) / 30.0) *
          ((COALESCE(eoh."endDate", eh."endDate") - COALESCE(eoh."startDate", eh."startDate")) + 1) AS calc_units,
          config."configvalue"->>'channel' AS "salesType",
          eod."gst" AS gst_value,
          ppr."pricePoint6",
          ppr."pricePoint6IncludingGst",
          p."vendorBaseCost",
          p."nationalAvgCost",
          eoh."spacePurchase",
          eoh."incrementalPercentage",
          eoh."advertisedPriceGst",
          eod."everydayUnits",
          eod."categoryforecast",
          eod."isCategoryForecastLocked",
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
      INNER JOIN "tEventOffer" eoh ON eod."offerId" = eoh."offerId" AND eod."offerNo" = eoh."offerNumber"
      INNER JOIN "tEvent" eh ON eh."eventId" = eoh."eventId"
      INNER JOIN "tProducts" p ON p."sku" = eod."sku" AND p."isActive" = true
      INNER JOIN "tPriceProductRules" ppr ON ppr."sku" = eod."sku"
          AND ppr."company" = eh."company"
          AND ppr."startDate" <= CURRENT_DATE AND ppr."endDate" >= CURRENT_DATE
          AND ppr."isActive" = TRUE
      INNER JOIN "tConfig" config ON config."configkey" = eh."channel" AND config."country" = eh."country" AND config."configtype" = 'SalesType'
      LEFT JOIN tmp_pivoted_prices_pctstd pp ON pp."sku" = eod."sku" AND pp."country" = eh."country" AND pp."company" = eh."company"
      LEFT JOIN tmp_inventory_soh_pctstd inv ON inv."sku" = eod."sku" AND inv."company" = eh."company"
      LEFT JOIN "tSalesY1" s ON s."sku" = eod."sku" AND s."company" = eh."company" AND s."salesType" = config."configvalue" ->> 'channel'
      LEFT JOIN "tRegionalAreaGroupAllocation" rag ON rag."allocationGroup" = 'DEFAULT' AND rag."country" = eh."country"
      WHERE eoh."OfferTypeId" IN (14) AND eh."status" IN ('Open', 'Locked')
  ),

  "baseRrpCalculation" AS (
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
      FROM updateEventOfferDtlForSTDRangePrice d
  ),

  calculationsForEventOfferDtlSTDRangePrice AS (
      SELECT
          d.*,
          d.base_rrp_price AS new_everydayPriceGst,
          CASE WHEN d."isCategoryForecastLocked" = FALSE
               THEN CAST(ROUND((d."incrementalPercentage"::numeric / 100) * ROUND(d.calc_units)::numeric) AS integer)
               ELSE d."categoryforecast"
          END AS categoryFcst,
          CASE WHEN d."clearance" = 'Y' THEN d.base_rrp_price
               ELSE ROUND(d."advertisedPriceGst", 2)
          END AS new_advertisedPriceGst,
          CASE WHEN d."clearance" = 'Y' THEN ROUND(d.base_rrp_price / (1 + COALESCE(d.gst_value, 0)), 2)
               ELSE ROUND(d."advertisedPriceGst" / (1 + COALESCE(d.gst_value, 0)), 2)
          END AS new_advertisedPrice,
          ROUND(d."nationalAvgCost", 2) AS natAvgCost
      FROM "baseRrpCalculation" d
  )
    UPDATE "tEventOfferDetail" e
    SET
        "everydayUnits" = ROUND(c.calc_units),
        "everydayPrice" = Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2),
        "everydayPriceGst" = c.new_everydayPriceGst,
        "everydayPriceGstSys" = c.new_everydayPriceGst,
        "advertisedPriceGst" = c.new_advertisedPriceGst,
        "advertisedPrice" = c.new_advertisedPrice,
        "calculatedSaveValue"= Round(c.new_everydayPriceGst-c.new_advertisedPriceGst,2),
        "calculatedSavePercentage" = CASE
    WHEN c.new_everydayPriceGst > 0 THEN ROUND(((c.new_everydayPriceGst - c.new_advertisedPriceGst) / c.new_everydayPriceGst)* 100, 2)
    ELSE 0
END,
        "categoryforecast" = c.categoryFcst,
        "forecastCost"=Round(ROUND(COALESCE(c."vendorBaseCost",0),2)*c.categoryFcst,2),
        "forecastSales"=Round(c.categoryFcst*ROUND(c.new_advertisedPriceGst,2),2),
        "incrementalForecast"=c.categoryFcst-ROUND(c.calc_units),
        "nationalAverageCost" = COALESCE(c.natAvgCost, 0),
        "clearanceIndicator" = CASE WHEN c."clearance" IS NULL OR TRIM(c."clearance") = '' THEN 'N' ELSE c."clearance" END,
         "forecastTradeMargin$" = ROUND((c.new_advertisedPrice - ROUND(COALESCE(c."vendorBaseCost",0),2)) * c.categoryFcst,2),
        "stockOnHandStore" = c.sohStore,
        "stockOnHandDC"    = c.sohDc,
        "LatestEffectiveCost" = ROUND(ROUND(COALESCE(c."vendorBaseCost",0),2),2),
        "categoryCost"        = COALESCE(c.natAvgCost, 0),

        "everydayExtendedUnitCost"  = ROUND(c.calc_units) * COALESCE(c.natAvgCost, 0),
        "everydayExtendedUnitSales" = ROUND(c.calc_units )* c.new_everydayPriceGst,

        "extendedAdvertisedPrice" = ROUND(c.calc_units )* COALESCE(c.new_advertisedPriceGst, 0),
        "everydayCost" = COALESCE(c.natAvgCost, 0),
        "incrementalSales"=Round(Round(c.categoryFcst*ROUND(c.new_advertisedPriceGst,2),2) - (ROUND(c.calc_units)*c.new_everydayPriceGst),2),
        "incrementalTrade$" =  ROUND( ROUND((c.new_advertisedPrice - ROUND(COALESCE(c."vendorBaseCost",0),2)) * c.categoryFcst,2) - ROUND((Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2)-ROUND(COALESCE(c."vendorBaseCost",0),2) )*ROUND(c.calc_units),2), 2),
        "forecastTradeMargin%" = CASE
        WHEN Round(c.categoryFcst*ROUND(c.new_advertisedPrice,2),2) > 0
        THEN
               ROUND(((c.new_advertisedPrice - ROUND(COALESCE(c."vendorBaseCost",0),2)) * c.categoryFcst) / (c.categoryFcst * c.new_advertisedPrice) * 100, 2)

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
         * ROUND(COALESCE(c."vendorBaseCost",0),2),
    2)
    FROM calculationsForEventOfferDtlSTDRangePrice c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId" IN (14);
    RAISE NOTICE '[%] END   UPDATE tEventOfferDetail | offerType=STD Range Price | offerTypeId=14', clock_timestamp();

-- ===================================================================================================
-- UPDATE tEventOfferDetail For PCT OFF RANGE
--===============================================================================================================

--updateEventOfferDtlForPCTOffRange

RAISE NOTICE '[%] START UPDATE tEventOfferDetail | offerType=PCT Off Range | offerTypeId=6', clock_timestamp();
WITH

  updateEventOfferDtlForPCTOffRange AS (
      SELECT
          eod."sku",
          eod."offerNo",
          eod."offerId",
          eoh."offerType",
          eoh."OfferTypeId",
          p."clearance",
          eoh."savePercent",
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
          p."vendorBaseCost",
          p."nationalAvgCost",
          eoh."incrementalPercentage",
          eod."everydayUnits",
          eod."categoryforecast",
          eoh."spacePurchase",
          eod."isCategoryForecastLocked",
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
      LEFT JOIN tmp_pivoted_prices_pctstd pp ON pp."sku" = eod."sku" AND pp."country" = eh."country" AND pp."company" = eh."company"
      LEFT JOIN tmp_inventory_soh_pctstd inv
          ON inv."sku" = eod."sku"
          AND inv."company" = eh."company"
       LEFT JOIN "tSalesY1" s
          ON s."sku" = eod."sku"
         AND s."company" = eh."company"
         AND s."salesType" = config."configvalue" ->> 'channel'
      LEFT JOIN "tRegionalAreaGroupAllocation" rag
           on rag."allocationGroup"='DEFAULT'
           AND rag."country" = eh."country"
      WHERE eoh."OfferTypeId" IN (6)
      AND eh."status" IN ('Open', 'Locked')
  ),

  "baseRrpCalculation" AS (
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
      FROM updateEventOfferDtlForPCTOffRange d
  ),

  calculationsForEventOfferDtlPCTOffRange AS (
      SELECT
          d.*,
          d.base_rrp_price AS new_everydayPriceGst,
          CASE
              WHEN d."isCategoryForecastLocked" = FALSE
              THEN CAST(ROUND((d."incrementalPercentage"::numeric / 100) * ROUND(d.calc_units)::numeric) AS integer)
              ELSE d."categoryforecast"
          END AS categoryFcst,
          CASE
              WHEN d."clearance" = 'Y' THEN d.base_rrp_price
              ELSE ROUND(d.base_rrp_price - (d.base_rrp_price * d."savePercent" / 100), 2)
          END AS new_advertisedPriceGst,
          CASE
              WHEN d."clearance" = 'Y' THEN ROUND(d.base_rrp_price / (1 + COALESCE(d.gst_value, 0)), 2)
              ELSE ROUND((d.base_rrp_price - (d.base_rrp_price * d."savePercent" / 100)) / (1 + COALESCE(d.gst_value, 0)), 2)
          END AS new_advertisedPrice
      FROM "baseRrpCalculation" d
  )
    UPDATE "tEventOfferDetail" e
    SET
        "everydayUnits" = ROUND(c.calc_units),
        "everydayPrice" = Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2),
        "everydayPriceGst" = c.new_everydayPriceGst,
        "everydayPriceGstSys" = c.new_everydayPriceGst,
        "advertisedPriceGst"= c.new_advertisedPriceGst,
        "advertisedPrice"= c.new_advertisedPrice,
"calculatedSaveValue"= Round(e."everydayPriceGst"-c.new_advertisedPriceGst,2),
        "calculatedSavePercentage" = CASE
    WHEN c.new_everydayPriceGst > 0 THEN ROUND(((c.new_everydayPriceGst - c.new_advertisedPriceGst) / c.new_everydayPriceGst)* 100, 2)
    ELSE 0
END,
"clearanceIndicator" = CASE WHEN c."clearance" IS NULL OR TRIM(c."clearance") = '' THEN 'N' ELSE c."clearance" END,
        "categoryforecast" = c.categoryFcst,
        "forecastCost"=Round(ROUND(COALESCE(c."vendorBaseCost",0),2)*c.categoryFcst,2),
        "forecastSales"=Round(c.categoryFcst*ROUND(c.new_advertisedPriceGst,2),2),
        "incrementalForecast"=c.categoryFcst-ROUND(c.calc_units),
        "nationalAverageCost" = COALESCE(c."nationalAvgCost", 0),
         "forecastTradeMargin$" = ROUND((c.new_advertisedPrice - ROUND(COALESCE(c."vendorBaseCost",0),2)) * c.categoryFcst,2),
        "stockOnHandStore" = c.sohStore,
        "stockOnHandDC"    = c.sohDc,
        "LatestEffectiveCost" = ROUND(ROUND(COALESCE(c."vendorBaseCost",0),2),2),
        "categoryCost"        = COALESCE(c."nationalAvgCost", 0),

        "everydayExtendedUnitCost"  = ROUND(c.calc_units )* COALESCE(c."nationalAvgCost", 0),
        "everydayExtendedUnitSales" = ROUND(c.calc_units )* c.new_everydayPriceGst,

        "extendedAdvertisedPrice" = ROUND(c.calc_units )* COALESCE(c.new_advertisedPriceGst, 0),
        "everydayCost" = COALESCE(c."nationalAvgCost", 0),
        "incrementalSales"=Round(Round(c.categoryFcst*ROUND(c.new_advertisedPriceGst,2),2) - (ROUND(c.calc_units)*c.new_everydayPriceGst),2),
        "incrementalTrade$" =  ROUND( ROUND((c.new_advertisedPrice - ROUND(COALESCE(c."vendorBaseCost",0),2)) * c.categoryFcst,2) - ROUND((Round(c.new_everydayPriceGst / (1 + COALESCE(c.gst_value, 0)),2)-ROUND(COALESCE(c."vendorBaseCost",0),2) )*ROUND(c.calc_units),2), 2),
        "forecastTradeMargin%" = CASE
        WHEN Round(c.categoryFcst*ROUND(c.new_advertisedPrice,2),2) > 0
        THEN
               ROUND(((c.new_advertisedPrice - ROUND(COALESCE(c."vendorBaseCost",0),2)) *c.categoryFcst) / (c.categoryFcst * c.new_advertisedPrice) * 100, 2)

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
         * ROUND(COALESCE(c."vendorBaseCost",0),2),
    2)
    FROM calculationsForEventOfferDtlPCTOffRange c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId" IN (6);
    RAISE NOTICE '[%] END   UPDATE tEventOfferDetail | offerType=PCT Off Range | offerTypeId=6', clock_timestamp();

--===============================================================================================================
-- UPDATE tEventOffer FOR STD RANGE PRICE
--===============================================================================================================

RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=STD Range Price | offerTypeId=14', clock_timestamp();
WITH EventOfferDtlSummaryForStdRangePrice AS (
    SELECT
        d."offerId",
        d."eventId",
        d."offerNo",
        d."gst" AS gst_value,
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
      AND d."offerNo" = o."offerNumber"
      AND d."offerId" = o."offerId"
      --AND COALESCE(d."isSkuActive", TRUE) = TRUE
      AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId",   d."offerNo", d."gst"
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
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=STD Range Price | offerTypeId=14', clock_timestamp();

  RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=STD Range Price | offerTypeId=14', clock_timestamp();
  WITH EventOfferDtlSummaryforAdvPriceForStdRangePrice AS (
    SELECT
        d."offerId",
        d."eventId",
        d."offerNo",
        d."gst" AS gst_value,
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
       AND d."offerNo" = o."offerNumber"
      AND d."offerId" = o."offerId"
      --AND COALESCE(d."isSkuActive", TRUE) = TRUE
      AND (d."clearanceIndicator" <> 'Y' OR d."clearanceIndicator" IS NULL)
      AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId",  d."clearanceIndicator", d."offerNo", d."gst"
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
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=STD Range Price | offerTypeId=14', clock_timestamp();

--===============================================================================================================
-- UPDATE tEventOffer For PCT OFF RANGE
--===============================================================================================================

-- EventOfferDtlSummaryForPCTOffRange
  RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=PCT Off Range | offerTypeId=6', clock_timestamp();
  WITH EventOfferDtlSummaryforAdvPriceForPCTOffRange  AS (
         SELECT
        d."offerId",
        d."eventId",
        d."offerNo",
        d."gst" AS gst_value,
        d."clearanceIndicator",

       MIN(d."advertisedPriceGst")                 AS "advPrice",
        MIN(d."calculatedSaveValue")        AS "saveValue",
        MIN(d."everydayPriceGst")              AS "everydayPrice",
        MIN(d."calculatedSavePercentage") AS "savePercent"

    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId" AND d."offerNo" = o."offerNumber" AND d."eventId" = o."eventId"
    WHERE  (o."OfferTypeId" IN (6))
      AND d."offerNo" = o."offerNumber"
      AND d."offerId" = o."offerId"
      --AND COALESCE(d."isSkuActive", TRUE) = TRUE
      AND (d."clearanceIndicator" <> 'Y' OR d."clearanceIndicator" IS NULL)
      AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId", d."offerNo", d."clearanceIndicator", d."gst"
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
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=PCT Off Range | offerTypeId=6', clock_timestamp();

   RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=PCT Off Range | offerTypeId=6', clock_timestamp();
   WITH EventOfferDtlSummaryForPCTOffRange  AS (
         SELECT
        d."offerId",
        d."eventId",
        d."offerNo",
        d."gst" AS gst_value,

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
      AND d."offerNo" = o."offerNumber"
      AND d."offerId" = o."offerId"
      --AND COALESCE(d."isSkuActive", TRUE) = TRUE
      AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."eventId", d."offerNo", d."gst"
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
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=PCT Off Range | offerTypeId=6', clock_timestamp();

--===============================================================================================================
-- UPDATE tMudMapDetail For STD Range Price and PCT OFF RANGE
--===============================================================================================================

RAISE NOTICE '[%] START UPDATE tMudMapDetail | offerType=STD Range Price & PCT Off Range (Regular Offers) | offerTypeId=NOT IN (4,15,3,5)', clock_timestamp();
WITH EventOfferDetailAgg AS (
      SELECT
          "eventId",
          "offerId",
          MIN(CASE WHEN "fromPriceIndicator" = true
                   THEN "advertisedPriceGst" END) AS "minFromPrice"
      FROM public."tEventOfferDetail"
      GROUP BY "eventId", "offerId"
  ),
RegularOffers AS (
    SELECT
        e."eventId",
        e."offerId",
        e."offerName",
        e."offerType",
        e."OfferTypeId",
        ev."status",
         CASE
              WHEN e."fromPrice" = true
              THEN ROUND(eod."minFromPrice",2)
              ELSE ROUND(SUM(
                  CASE
                      WHEN COALESCE(e."advertisedPriceGst", 0) > 9999999 THEN 0
                      ELSE COALESCE(e."advertisedPriceGst", 0)
                  END
              ),2)
          END AS "advertisedPrice",
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
        e."offerQuantity" AS "PurchaseQuantity",
        e."freeQuantity" AS "FreeQuantity"
    FROM public."tEventOffer" AS e
    INNER JOIN public."tEvent" AS ev ON e."eventId" = ev."eventId"
     LEFT JOIN EventOfferDetailAgg as eod ON eod."eventId"=e."eventId" AND eod."offerId"=e."offerId"
    WHERE e."OfferTypeId" NOT IN (4,15)
      AND e."OfferTypeId" <> 3
      AND e."OfferTypeId" <> 5
      AND ev."status" IN ('Open', 'Locked')
    GROUP BY
        e."eventId", e."offerId", e."offerName", e."offerType", e."OfferTypeId",ev."status",
        e."country", e."requiredQuantity", e."fromPrice", e."offerQuantity", e."freeQuantity", eod."minFromPrice"
)
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
RAISE NOTICE '[%] END   UPDATE tMudMapDetail | offerType=STD Range Price & PCT Off Range (Regular Offers) | offerTypeId=NOT IN (4,15,3,5)', clock_timestamp();

  RAISE NOTICE 'Event offer details updated successfully for all SKUs.';

  v_end_time := clock_timestamp();

    UPDATE execution_log
    SET status      = 'SUCCESS',
        end_time    = v_end_time,
        duration_ms = (EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000)::bigint
    WHERE id = v_log_id;

EXCEPTION
    WHEN OTHERS THEN
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
