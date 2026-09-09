-- PROCEDURE: public.sp_update_event_offer_detailscombomultibuybxgy()

-- DROP PROCEDURE IF EXISTS public.sp_update_event_offer_detailscombomultibuybxgy();

CREATE OR REPLACE PROCEDURE public.sp_update_event_offer_detailscombomultibuybxgy(
	)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_start_time timestamptz;
    v_end_time   timestamptz;
    v_log_id     bigint;
    v_job_name   text := 'sp_update_event_offer_detailscomboMultiBuyBXGY';
BEGIN
    -- Use AEST (Australia/Sydney) for all timestamps in this run
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
    DROP TABLE IF EXISTS tmp_pivoted_prices_combomultibuybxgy;
    CREATE TEMP TABLE tmp_pivoted_prices_combomultibuybxgy AS
    WITH "relevantSkus" AS (
        SELECT DISTINCT eod."sku"
        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
        WHERE eh."status" IN ('Open', 'Locked')
          AND eoh."OfferTypeId" IN (3, 5, 4)
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
          AND pld."startDate" <= CURRENT_DATE
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

    CREATE INDEX ON tmp_pivoted_prices_combomultibuybxgy ("sku","country","company");
    ANALYZE tmp_pivoted_prices_combomultibuybxgy;
    RAISE NOTICE '[%] tmp_pivoted_prices_combomultibuybxgy built', clock_timestamp();

    -- ------------------------------------------------------------------
    -- PERF: materialise the FUTURE price-list waterfall ONCE for this run,
    -- mirroring tmp_pivoted_prices_combomultibuybxgy but scoped to future-dated rows
    -- (tPriceListDetail can now hold future-dated rows per a companion
    -- ingestion change). Nearest future date wins (ORDER BY ASC).
    -- ------------------------------------------------------------------
    DROP TABLE IF EXISTS tmp_future_pivoted_prices_combomultibuybxgy;
    CREATE TEMP TABLE tmp_future_pivoted_prices_combomultibuybxgy AS
    WITH "relevantSkus" AS (
        SELECT DISTINCT eod."sku"
        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
        WHERE eh."status" IN ('Open', 'Locked')
          AND eoh."OfferTypeId" IN (3, 5, 4)
          AND eod."isSkuActive" = TRUE
    ),
    "futurePricelistDetail" AS (
        SELECT
            pld."sku",
            pld."priceList",
            pld."priceListPrice",
            pld."startDate",
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
                ORDER BY pld."startDate" ASC
            ) AS group_rn
        FROM "tPriceListDetail" pld
        INNER JOIN "tPriceList" pl ON pld."priceList" = pl."priceList"
        WHERE pld."priceList" IN ('050','184','499','498','390','419','824','343','446','241','036','371','274','211','044','134','021','492')
          AND pld."isActive"
          AND pld."startDate" > CURRENT_DATE
          AND pld."sku" IN (SELECT "sku" FROM "relevantSkus")
    )
    SELECT
        t.*,
        CASE WHEN t."country" = 'AU' THEN LEAST(t.clearance_price_050, t.priceList184)
             WHEN t."country" = 'NZ' THEN LEAST(t.priceList499, t.priceList498) END AS future_special_price,
        -- The startDate belonging to whichever of the special-price pair (clearance_price_050/priceList184
        -- for AU, priceList499/priceList498 for NZ) actually wins the LEAST() above -- mirrors that CASE
        -- exactly so the date always matches the selected price, not just whichever side has the earlier date.
        CASE
            WHEN t."country" = 'AU' THEN
                CASE
                    WHEN LEAST(t.clearance_price_050, t.priceList184) IS NULL THEN NULL
                    WHEN t.clearance_price_050 IS NULL THEN t.pricelist184_startdate
                    WHEN t.priceList184 IS NULL THEN t.clearance_price_050_startdate
                    WHEN t.clearance_price_050 <= t.priceList184 THEN t.clearance_price_050_startdate
                    ELSE t.pricelist184_startdate
                END
            WHEN t."country" = 'NZ' THEN
                CASE
                    WHEN LEAST(t.priceList499, t.priceList498) IS NULL THEN NULL
                    WHEN t.priceList499 IS NULL THEN t.pricelist498_startdate
                    WHEN t.priceList498 IS NULL THEN t.pricelist499_startdate
                    WHEN t.priceList499 <= t.priceList498 THEN t.pricelist499_startdate
                    ELSE t.pricelist498_startdate
                END
        END AS future_special_price_startdate,
        t.au_primary_price AS future_au_primary,
        t.au_primary_price_startdate AS future_au_primary_startdate,
        t.au_fallback_price_036 AS future_au_fallback_036,
        t.au_fallback_price_036_startdate AS future_au_fallback_036_startdate,
        t.nz_primary_price AS future_nz_primary,
        t.nz_primary_price_startdate AS future_nz_primary_startdate,
        t.nz_fallback_price_492 AS future_nz_fallback_492,
        t.nz_fallback_price_492_startdate AS future_nz_fallback_492_startdate
    FROM (
        SELECT
            "sku","country","company",
            MAX(CASE WHEN "priceList" = '050' AND group_rn = 1 THEN "priceListPrice" END) AS clearance_price_050,
            MAX(CASE WHEN "priceList" = '050' AND group_rn = 1 THEN "startDate" END) AS clearance_price_050_startdate,
            MAX(CASE WHEN "priceList" = '184' AND group_rn = 1 THEN "priceListPrice" END) AS priceList184,
            MAX(CASE WHEN "priceList" = '184' AND group_rn = 1 THEN "startDate" END) AS pricelist184_startdate,
            MAX(CASE WHEN "priceList" = '499' AND group_rn = 1 THEN "priceListPrice" END) AS priceList499,
            MAX(CASE WHEN "priceList" = '499' AND group_rn = 1 THEN "startDate" END) AS pricelist499_startdate,
            MAX(CASE WHEN "priceList" = '498' AND group_rn = 1 THEN "priceListPrice" END) AS priceList498,
            MAX(CASE WHEN "priceList" = '498' AND group_rn = 1 THEN "startDate" END) AS pricelist498_startdate,
            MAX(CASE WHEN "priceList" IN ('390','419','824','343','446','241') AND group_rn = 1 THEN "priceListPrice" END) AS au_primary_price,
            MAX(CASE WHEN "priceList" IN ('390','419','824','343','446','241') AND group_rn = 1 THEN "startDate" END) AS au_primary_price_startdate,
            MAX(CASE WHEN "priceList" = '036' AND group_rn = 1 THEN "priceListPrice" END) AS au_fallback_price_036,
            MAX(CASE WHEN "priceList" = '036' AND group_rn = 1 THEN "startDate" END) AS au_fallback_price_036_startdate,
            MAX(CASE WHEN "priceList" IN ('371','274','211','044','134','021') AND group_rn = 1 THEN "priceListPrice" END) AS nz_primary_price,
            MAX(CASE WHEN "priceList" IN ('371','274','211','044','134','021') AND group_rn = 1 THEN "startDate" END) AS nz_primary_price_startdate,
            MAX(CASE WHEN "priceList" = '492' AND group_rn = 1 THEN "priceListPrice" END) AS nz_fallback_price_492,
            MAX(CASE WHEN "priceList" = '492' AND group_rn = 1 THEN "startDate" END) AS nz_fallback_price_492_startdate
        FROM "futurePricelistDetail"
        WHERE group_rn = 1
        GROUP BY "sku","country","company"
    ) t;

    CREATE INDEX ON tmp_future_pivoted_prices_combomultibuybxgy ("sku","country","company");
    ANALYZE tmp_future_pivoted_prices_combomultibuybxgy;
    RAISE NOTICE '[%] tmp_future_pivoted_prices_combomultibuybxgy built', clock_timestamp();

    -- ------------------------------------------------------------------
    -- PERF: materialise relevantSkuCompanies ONCE for this run.
    -- Previously this identical CTE (distinct sku/company for
    -- OPEN/LOCKED events of the relevant offer types) was recomputed
    -- 3 times over (inventory, current RRP, future RRP). Build it a
    -- single time here and index it so all three joins reuse it.
    -- ------------------------------------------------------------------
    DROP TABLE IF EXISTS tmp_relevant_sku_companies_combo;
    CREATE TEMP TABLE tmp_relevant_sku_companies_combo AS
    SELECT DISTINCT eod."sku", eh."company", eh."country"
    FROM "tEventOfferDetail" eod
    INNER JOIN "tEventOffer" eoh
        ON eod."offerId" = eoh."offerId"
       AND eod."offerNo" = eoh."offerNumber"
    INNER JOIN "tEvent" eh
        ON eh."eventId" = eoh."eventId"
    WHERE eh."status" IN ('Open', 'Locked')
      AND eoh."OfferTypeId" IN (3, 5, 4)
      AND eod."isSkuActive" = TRUE;

    CREATE INDEX ON tmp_relevant_sku_companies_combo ("sku", "company");
    ANALYZE tmp_relevant_sku_companies_combo;
    RAISE NOTICE '[%] tmp_relevant_sku_companies_combo built', clock_timestamp();

    -- ------------------------------------------------------------------
    -- PERF: pre-aggregate tInventory by (sku, company) ONCE.
    -- tInventory has many rows per SKU (one per store/location). Joining
    -- it raw causes massive row multiplication in every UPDATE CTE,
    -- forcing expensive GROUP BYs. Pre-aggregating reduces each
    -- (sku, company) to a single row with sohStore/sohDc already summed.
    -- ------------------------------------------------------------------
    DROP TABLE IF EXISTS tmp_inventory_soh_combo;
    CREATE TEMP TABLE tmp_inventory_soh_combo AS
    SELECT
        rc."sku",
        rc."company",
        rc."country",
        COALESCE(SUM(CASE WHEN UPPER(inv."locationType") = 'STORE' THEN inv."onHand" END), 0) AS "sohStore",
        COALESCE(SUM(CASE WHEN UPPER(inv."locationType") <> 'STORE' THEN inv."onHand" END), 0) AS "sohDc"
    FROM tmp_relevant_sku_companies_combo rc
    LEFT JOIN "tInventory" inv
        ON inv."sku" = rc."sku"
       AND inv."company" IN (rc."company", '12', '52')
    GROUP BY rc."sku", rc."company", rc."country";

    CREATE INDEX ON tmp_inventory_soh_combo ("sku", "company");
    ANALYZE tmp_inventory_soh_combo;
    RAISE NOTICE '[%] tmp_inventory_soh_combo built - starting detail updates', clock_timestamp();

    -- ------------------------------------------------------------------
    -- PERF: resolve the CURRENT active price rule ONCE for this run.
    -- Previously every UPDATE re-ran an INNER JOIN "tPriceProductRules" ppr
    -- filtered by startDate/endDate/isActive inline, three times over.
    -- Build it a single time here, scoped to the same relevantSkuCompanies
    -- used for inventory, then index it. Defensive ROW_NUMBER() guards
    -- against any overlapping active rules for the same sku/company.
    -- ------------------------------------------------------------------
    DROP TABLE IF EXISTS tmp_current_rrp_combo;
    CREATE TEMP TABLE tmp_current_rrp_combo AS
    WITH "rankedCurrentRrp" AS (
        SELECT
            ppr."sku",
            ppr."company",
            rc."country",
            ppr."pricePoint6",
            ppr."pricePoint6IncludingGst",
            ROW_NUMBER() OVER (
                PARTITION BY ppr."sku", ppr."company"
                ORDER BY ppr."startDate" DESC
            ) AS rn
        FROM "tPriceProductRules" ppr
        INNER JOIN tmp_relevant_sku_companies_combo rc
            ON rc."sku" = ppr."sku"
           AND rc."company" = ppr."company"
        WHERE ppr."startDate" <= CURRENT_DATE
          AND ppr."endDate" >= CURRENT_DATE
          AND ppr."isActive" = TRUE
    )
    SELECT
        "sku",
        "company",
        "country",
        "pricePoint6",
        "pricePoint6IncludingGst"
    FROM "rankedCurrentRrp"
    WHERE rn = 1;

    CREATE INDEX ON tmp_current_rrp_combo (sku, company);
    ANALYZE tmp_current_rrp_combo;
    RAISE NOTICE '[%] tmp_current_rrp_combo built', clock_timestamp();

    -- ------------------------------------------------------------------
    -- PERF: resolve the NEAREST future price rule ONCE for this run.
    -- Supports surfacing an upcoming RRP change alongside the current
    -- price without re-querying tPriceProductRules per offer type.
    -- Scoped to the same relevantSkuCompanies as the current-RRP table.
    -- ------------------------------------------------------------------
    DROP TABLE IF EXISTS tmp_future_rrp_combo;
    CREATE TEMP TABLE tmp_future_rrp_combo AS
    SELECT
        ppr."sku",
        ppr."company",
        rc."country",
        ppr."pricePoint6IncludingGst",
        ppr."startDate"
    FROM "tPriceProductRules" ppr
    INNER JOIN tmp_relevant_sku_companies_combo rc
        ON rc."sku" = ppr."sku"
       AND rc."company" = ppr."company"
    WHERE ppr."startDate" > CURRENT_DATE
      AND ppr."isActive" = TRUE;

    CREATE INDEX ON tmp_future_rrp_combo (sku, company);
    ANALYZE tmp_future_rrp_combo;
    RAISE NOTICE '[%] tmp_future_rrp_combo built', clock_timestamp();


-- ===================================================================================================
-- UPDATE tEventOfferDetail For Combo
--===============================================================================================================

 RAISE NOTICE '[%] START UPDATE tEventOfferDetail | offerType=Combo | offerTypeId=3', clock_timestamp();
 WITH

      updateEventOfferDtlForCombo  AS (
        SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
            eoh."OfferTypeId",
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
            eoh."spacePurchase",
            eh."country",
            COALESCE(inv."sohStore", 0) AS sohStore,
            COALESCE(inv."sohDc", 0) AS sohDc,

            pp.clearance_price_050,
            pp.priceList184,
            pp.priceList499,
            pp.priceList498,
            CASE
                WHEN eh."country" = 'AU' THEN
                    CASE
                        WHEN pp.clearance_price_050 IS NOT NULL
                             AND pp.priceList184 IS NOT NULL
                        THEN
                            CASE
                                WHEN pp.clearance_price_050 <= pp.priceList184
                                    THEN 'Clearance'
                                WHEN pp.clearance_price_050 > pp.priceList184
                                    THEN 'Mgr Special'
                            END

                        WHEN pp.clearance_price_050 IS NOT NULL
                            THEN 'Clearance'

                        WHEN pp.priceList184 IS NOT NULL
                            THEN 'Mgr Special'

                        ELSE 'N'
                    END

                WHEN eh."country" = 'NZ' THEN
                    CASE
                        WHEN pp.priceList499 IS NOT NULL
                             AND pp.priceList498 IS NOT NULL
                        THEN
                            CASE
                                WHEN pp.priceList499 > pp.priceList498
                                    THEN 'Mgr Special'
                                WHEN pp.priceList499 <= pp.priceList498
                                    THEN 'Clearance'
                            END

                        WHEN pp.priceList499 IS NOT NULL
                            THEN 'Clearance'

                        WHEN pp.priceList498 IS NOT NULL
                            THEN 'Mgr Special'

                        ELSE 'N'
                    END

                ELSE 'N'
            END AS clearance,
            pp.au_primary_price,
            pp.au_fallback_price_036,
            pp.nz_primary_price,
            pp.nz_fallback_price_492,
            pp.special_price,
            pp.au_primary,
            pp.au_fallback_036,
            pp.nz_primary,
            pp.nz_fallback_492,

            fpp.future_special_price,
            fpp.future_special_price_startdate,
            fpp.future_au_primary,
            fpp.future_au_primary_startdate,
            fpp.future_au_fallback_036,
            fpp.future_au_fallback_036_startdate,
            fpp.future_nz_primary,
            fpp.future_nz_primary_startdate,
            fpp.future_nz_fallback_492,
            fpp.future_nz_fallback_492_startdate,

            future_ppr."pricePoint6IncludingGst" AS "futurePricePoint6IncludingGst",
            future_ppr."startDate" AS "futurePprStartDate"

        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
             INNER JOIN "tProducts" p
            ON p."sku" = eod."sku" and p."isActive"=true
        INNER JOIN tmp_current_rrp_combo ppr
            ON ppr."sku" = eod."sku"
            AND ppr."company" = eh."company"
        LEFT JOIN tmp_future_rrp_combo future_ppr
            ON future_ppr."sku" = eod."sku"
            AND future_ppr."company" = eh."company"

        INNER JOIN "tConfig" config
            ON config."configkey" = eh."channel"
           AND config."country" = eh."country"
           AND config."configtype" = 'SalesType'
        LEFT JOIN tmp_pivoted_prices_combomultibuybxgy pp ON pp."sku" = eod."sku"  AND pp."country" = eh."country" AND pp."company" = eh."company"
        LEFT JOIN tmp_future_pivoted_prices_combomultibuybxgy fpp ON fpp."sku" = eod."sku" AND fpp."country" = eh."country" AND fpp."company" = eh."company"
         LEFT JOIN tmp_inventory_soh_combo inv
            ON inv."sku" = eod."sku"
            AND inv."company" = eh."company"
         LEFT JOIN "tSalesY1" s
            ON s."sku" = eod."sku"
           AND s."company" = eh."company"
           AND s."salesType" = config."configvalue" ->> 'channel'
        LEFT JOIN "tRegionalAreaGroupAllocation" rag
             on rag."allocationGroup"='DEFAULT'
             AND rag."country" = eh."country"
        WHERE eoh."OfferTypeId" IN (3)
        AND eh."status" IN ('Open', 'Locked')
    ),

    "baseRrpCalculation_Combo" AS (
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
                END AS base_rrp_price,
            -- Future price-list waterfall result (special -> primary -> fallback),
            -- computed independently of source so it can be compared against the
            -- future PPR pricePoint6 result below and the earlier date can win.
            CASE
                WHEN d."country" = 'AU' THEN
                    COALESCE(d.future_special_price, d.future_au_primary, d.future_au_fallback_036)
                WHEN d."country" = 'NZ' THEN
                    COALESCE(d.future_special_price, d.future_nz_primary, d.future_nz_fallback_492)
            END AS future_pricelist_rrp,
            -- The startDate belonging to whichever tier future_pricelist_rrp actually resolved
            -- to above -- mirrors that COALESCE exactly so the date always matches the selected
            -- price, not just whichever tier happens to have the earliest date.
            CASE
                WHEN d."country" = 'AU' THEN
                    CASE
                        WHEN d.future_special_price IS NOT NULL THEN d.future_special_price_startdate
                        WHEN d.future_au_primary IS NOT NULL THEN d.future_au_primary_startdate
                        WHEN d.future_au_fallback_036 IS NOT NULL THEN d.future_au_fallback_036_startdate
                    END
                WHEN d."country" = 'NZ' THEN
                    CASE
                        WHEN d.future_special_price IS NOT NULL THEN d.future_special_price_startdate
                        WHEN d.future_nz_primary IS NOT NULL THEN d.future_nz_primary_startdate
                        WHEN d.future_nz_fallback_492 IS NOT NULL THEN d.future_nz_fallback_492_startdate
                    END
            END AS future_pricelist_start_date,
            -- Future PPR pricePoint6 result, rounded the same way as base_rrp_price's fallback.
            CASE
                WHEN d."futurePricePoint6IncludingGst" IS NULL THEN NULL
                ELSE
                    ROUND(
                        CASE
                            WHEN (ROUND(d."futurePricePoint6IncludingGst", 2)) < 1 THEN
                                CEILING((ROUND(d."futurePricePoint6IncludingGst", 2)) * 10) / 10.0
                            WHEN (ROUND(d."futurePricePoint6IncludingGst", 2)) < 10 THEN
                                CASE WHEN ((ROUND(d."futurePricePoint6IncludingGst", 2)) - FLOOR(ROUND(d."futurePricePoint6IncludingGst", 2))) > 0.5
                                     THEN CEILING(ROUND(d."futurePricePoint6IncludingGst", 2))
                                     ELSE FLOOR(ROUND(d."futurePricePoint6IncludingGst", 2))
                                END
                            ELSE CEILING(ROUND(d."futurePricePoint6IncludingGst", 2))
                        END, 2
                    )
            END AS future_ppr_rrp
        FROM updateEventOfferDtlForCombo d
    ),
    "baseRrpCalculation_ComboResolved" AS (
        SELECT
            d.*,
            CASE
                WHEN d.future_pricelist_rrp IS NOT NULL
                     AND (d."futurePprStartDate" IS NULL OR d.future_pricelist_start_date <= d."futurePprStartDate")
                THEN d.future_pricelist_rrp
                WHEN d.future_ppr_rrp IS NOT NULL
                THEN d.future_ppr_rrp
                ELSE d.future_pricelist_rrp
            END AS future_rrp_price,
            CASE
                WHEN d.future_pricelist_rrp IS NOT NULL
                     AND (d."futurePprStartDate" IS NULL OR d.future_pricelist_start_date <= d."futurePprStartDate")
                THEN d.future_pricelist_start_date
                WHEN d.future_ppr_rrp IS NOT NULL
                THEN d."futurePprStartDate"
                ELSE d.future_pricelist_start_date
            END AS future_rrp_effective_date
        FROM "baseRrpCalculation_Combo" d
    ),

    calculationsForEventOfferDtlCombo AS (
        SELECT
            d.*,
            d.base_rrp_price AS new_everydayPriceGst,
            CASE WHEN d.clearance NOT LIKE 'N' THEN d.base_rrp_price
                 ELSE d."advertisedPriceGst"
            END AS new_advertisedPriceGst,
            CASE WHEN d.clearance NOT LIKE 'N' THEN ROUND(d.base_rrp_price / (1 + COALESCE(d.gst_value, 0)),2)
                 ELSE ROUND((d."advertisedPriceGst") / (1 + COALESCE(d.gst_value, 0)),2)
            END AS new_advertisedPrice,
            ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM "baseRrpCalculation_ComboResolved" d
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
        "clearanceIndicator" = c.clearance,
        "calculatedSavePercentage" = CASE
    WHEN c.new_everydayPriceGst > 0 THEN ROUND(((c.new_everydayPriceGst - c.new_advertisedPriceGst) / c.new_everydayPriceGst)* 100, 2)
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

        "extendedAdvertisedPrice" = ROUND(c.calc_units )* COALESCE(c.new_advertisedPriceGst, 0),
        "everydayCost" = COALESCE(c.natAvgCost, 0),
        "futureEdPrice" = c.future_rrp_price,
        "futureEdEffectiveDate" = c.future_rrp_effective_date,
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
    FROM calculationsForEventOfferDtlCombo c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId" IN (3);
    RAISE NOTICE '[%] END   UPDATE tEventOfferDetail | offerType=Combo | offerTypeId=3', clock_timestamp();

-- ===================================================================================================
-- UPDATE tEventOfferDetail For BXGY
--===============================================================================================================

 RAISE NOTICE '[%] START UPDATE tEventOfferDetail | offerType=BXGY | offerTypeId=5', clock_timestamp();
 WITH

      updateEventOfferDtlForBXGY AS (
        SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
            eoh."OfferTypeId",
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
            eoh."spacePurchase",
            eh."country",
            COALESCE(inv."sohStore", 0) AS sohStore,
            COALESCE(inv."sohDc", 0) AS sohDc,

            pp.clearance_price_050,
            pp.priceList184,
            pp.priceList499,
            pp.priceList498,
            CASE
                WHEN eh."country" = 'AU' THEN
                    CASE
                        WHEN pp.clearance_price_050 IS NOT NULL
                             AND pp.priceList184 IS NOT NULL
                        THEN
                            CASE
                                WHEN pp.clearance_price_050 <= pp.priceList184
                                    THEN 'Clearance'
                                WHEN pp.clearance_price_050 > pp.priceList184
                                    THEN 'Mgr Special'
                            END

                        WHEN pp.clearance_price_050 IS NOT NULL
                            THEN 'Clearance'

                        WHEN pp.priceList184 IS NOT NULL
                            THEN 'Mgr Special'

                        ELSE 'N'
                    END

                WHEN eh."country" = 'NZ' THEN
                    CASE
                        WHEN pp.priceList499 IS NOT NULL
                             AND pp.priceList498 IS NOT NULL
                        THEN
                            CASE
                                WHEN pp.priceList499 > pp.priceList498
                                    THEN 'Mgr Special'
                                WHEN pp.priceList499 <= pp.priceList498
                                    THEN 'Clearance'
                            END

                        WHEN pp.priceList499 IS NOT NULL
                            THEN 'Clearance'

                        WHEN pp.priceList498 IS NOT NULL
                            THEN 'Mgr Special'

                        ELSE 'N'
                    END

                ELSE 'N'
            END AS clearance,
            pp.au_primary_price,
            pp.au_fallback_price_036,
            pp.nz_primary_price,
            pp.nz_fallback_price_492,
            pp.special_price,
            pp.au_primary,
            pp.au_fallback_036,
            pp.nz_primary,
            pp.nz_fallback_492,

            fpp.future_special_price,
            fpp.future_special_price_startdate,
            fpp.future_au_primary,
            fpp.future_au_primary_startdate,
            fpp.future_au_fallback_036,
            fpp.future_au_fallback_036_startdate,
            fpp.future_nz_primary,
            fpp.future_nz_primary_startdate,
            fpp.future_nz_fallback_492,
            fpp.future_nz_fallback_492_startdate,

            future_ppr."pricePoint6IncludingGst" AS "futurePricePoint6IncludingGst",
            future_ppr."startDate" AS "futurePprStartDate"

        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
            INNER JOIN "tProducts" p
            ON p."sku" = eod."sku" and p."isActive"=true
        INNER JOIN tmp_current_rrp_combo ppr
            ON ppr."sku" = eod."sku"
            AND ppr."company" = eh."company"
        LEFT JOIN tmp_future_rrp_combo future_ppr
            ON future_ppr."sku" = eod."sku"
            AND future_ppr."company" = eh."company"

        INNER JOIN "tConfig" config
            ON config."configkey" = eh."channel"
           AND config."country" = eh."country"
           AND config."configtype" = 'SalesType'
        LEFT JOIN tmp_pivoted_prices_combomultibuybxgy pp ON pp."sku" = eod."sku" AND pp."country" = eh."country" AND pp."company" = eh."company"
        LEFT JOIN tmp_future_pivoted_prices_combomultibuybxgy fpp ON fpp."sku" = eod."sku" AND fpp."country" = eh."country" AND fpp."company" = eh."company"
         LEFT JOIN tmp_inventory_soh_combo inv
            ON inv."sku" = eod."sku"
            AND inv."company" = eh."company"
         LEFT JOIN "tSalesY1" s
            ON s."sku" = eod."sku"
           AND s."company" = eh."company"
           AND s."salesType" = config."configvalue" ->> 'channel'
        LEFT JOIN "tRegionalAreaGroupAllocation" rag
             on rag."allocationGroup"='DEFAULT'
             AND rag."country" = eh."country"
        WHERE eoh."OfferTypeId" IN (5)
        AND eh."status" IN ('Open', 'Locked')
    ),

    "baseRrpCalculation_BXGY" AS (
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
                END AS base_rrp_price,
            -- Future price-list waterfall result (special -> primary -> fallback),
            -- computed independently of source so it can be compared against the
            -- future PPR pricePoint6 result below and the earlier date can win.
            CASE
                WHEN d."country" = 'AU' THEN
                    COALESCE(d.future_special_price, d.future_au_primary, d.future_au_fallback_036)
                WHEN d."country" = 'NZ' THEN
                    COALESCE(d.future_special_price, d.future_nz_primary, d.future_nz_fallback_492)
            END AS future_pricelist_rrp,
            -- The startDate belonging to whichever tier future_pricelist_rrp actually resolved
            -- to above -- mirrors that COALESCE exactly so the date always matches the selected
            -- price, not just whichever tier happens to have the earliest date.
            CASE
                WHEN d."country" = 'AU' THEN
                    CASE
                        WHEN d.future_special_price IS NOT NULL THEN d.future_special_price_startdate
                        WHEN d.future_au_primary IS NOT NULL THEN d.future_au_primary_startdate
                        WHEN d.future_au_fallback_036 IS NOT NULL THEN d.future_au_fallback_036_startdate
                    END
                WHEN d."country" = 'NZ' THEN
                    CASE
                        WHEN d.future_special_price IS NOT NULL THEN d.future_special_price_startdate
                        WHEN d.future_nz_primary IS NOT NULL THEN d.future_nz_primary_startdate
                        WHEN d.future_nz_fallback_492 IS NOT NULL THEN d.future_nz_fallback_492_startdate
                    END
            END AS future_pricelist_start_date,
            -- Future PPR pricePoint6 result, rounded the same way as base_rrp_price's fallback.
            CASE
                WHEN d."futurePricePoint6IncludingGst" IS NULL THEN NULL
                ELSE
                    ROUND(
                        CASE
                            WHEN (ROUND(d."futurePricePoint6IncludingGst", 2)) < 1 THEN
                                CEILING((ROUND(d."futurePricePoint6IncludingGst", 2)) * 10) / 10.0
                            WHEN (ROUND(d."futurePricePoint6IncludingGst", 2)) < 10 THEN
                                CASE WHEN ((ROUND(d."futurePricePoint6IncludingGst", 2)) - FLOOR(ROUND(d."futurePricePoint6IncludingGst", 2))) > 0.5
                                     THEN CEILING(ROUND(d."futurePricePoint6IncludingGst", 2))
                                     ELSE FLOOR(ROUND(d."futurePricePoint6IncludingGst", 2))
                                END
                            ELSE CEILING(ROUND(d."futurePricePoint6IncludingGst", 2))
                        END, 2
                    )
            END AS future_ppr_rrp
        FROM updateEventOfferDtlForBXGY d
    ),
    "baseRrpCalculation_BXGYResolved" AS (
        SELECT
            d.*,
            CASE
                WHEN d.future_pricelist_rrp IS NOT NULL
                     AND (d."futurePprStartDate" IS NULL OR d.future_pricelist_start_date <= d."futurePprStartDate")
                THEN d.future_pricelist_rrp
                WHEN d.future_ppr_rrp IS NOT NULL
                THEN d.future_ppr_rrp
                ELSE d.future_pricelist_rrp
            END AS future_rrp_price,
            CASE
                WHEN d.future_pricelist_rrp IS NOT NULL
                     AND (d."futurePprStartDate" IS NULL OR d.future_pricelist_start_date <= d."futurePprStartDate")
                THEN d.future_pricelist_start_date
                WHEN d.future_ppr_rrp IS NOT NULL
                THEN d."futurePprStartDate"
                ELSE d.future_pricelist_start_date
            END AS future_rrp_effective_date
        FROM "baseRrpCalculation_BXGY" d
    ),

    calculationsForEventOfferDtlBXGY AS (
        SELECT
            d.*,
            d.base_rrp_price AS new_everydayPriceGst,
            CASE
            WHEN d."offerNo" = 2 THEN 0
            WHEN d.clearance NOT LIKE 'N' THEN d.base_rrp_price
            ELSE d."advertisedPriceGst" END AS new_advertisedPriceGst,
            CASE
            WHEN d."offerNo" = 2 THEN 0
            WHEN d.clearance NOT LIKE 'N' THEN ROUND(d.base_rrp_price / (1 + COALESCE(d.gst_value, 0)),2)
            ELSE ROUND((d."advertisedPriceGst") / (1 + COALESCE(d.gst_value, 0)),2) END AS new_advertisedPrice,
            ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM "baseRrpCalculation_BXGYResolved" d
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
        "clearanceIndicator" = c.clearance,
        "calculatedSavePercentage" = CASE
    WHEN c.new_everydayPriceGst > 0 THEN ROUND(((c.new_everydayPriceGst - c.new_advertisedPriceGst) / c.new_everydayPriceGst)* 100, 2)
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

        "extendedAdvertisedPrice" = ROUND(c.calc_units )* COALESCE(c.new_advertisedPriceGst, 0),
        "everydayCost" = COALESCE(c.natAvgCost, 0),
        "futureEdPrice" = c.future_rrp_price,
        "futureEdEffectiveDate" = c.future_rrp_effective_date,
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
    FROM calculationsForEventOfferDtlBXGY c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId" IN (5);
    RAISE NOTICE '[%] END   UPDATE tEventOfferDetail | offerType=BXGY | offerTypeId=5', clock_timestamp();

-- ===================================================================================================
-- UPDATE tEventOfferDetail For MultiBuy
--===============================================================================================================

 RAISE NOTICE '[%] START UPDATE tEventOfferDetail | offerType=MultiBuy | offerTypeId=4', clock_timestamp();
 WITH

      updateEventOfferDtlForMultiBuy AS (
        SELECT
            eod."sku",
            eod."offerNo",
            eod."offerId",
            eoh."offerType",
            eoh."OfferTypeId",
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
            pp.priceList499,
            pp.priceList498,
            CASE
                WHEN eh."country" = 'AU' THEN
                    CASE
                        WHEN pp.clearance_price_050 IS NOT NULL
                             AND pp.priceList184 IS NOT NULL
                        THEN
                            CASE
                                WHEN pp.clearance_price_050 <= pp.priceList184
                                    THEN 'Clearance'
                                WHEN pp.clearance_price_050 > pp.priceList184
                                    THEN 'Mgr Special'
                            END

                        WHEN pp.clearance_price_050 IS NOT NULL
                            THEN 'Clearance'

                        WHEN pp.priceList184 IS NOT NULL
                            THEN 'Mgr Special'

                        ELSE 'N'
                    END

                WHEN eh."country" = 'NZ' THEN
                    CASE
                        WHEN pp.priceList499 IS NOT NULL
                             AND pp.priceList498 IS NOT NULL
                        THEN
                            CASE
                                WHEN pp.priceList499 > pp.priceList498
                                    THEN 'Mgr Special'
                                WHEN pp.priceList499 <= pp.priceList498
                                    THEN 'Clearance'
                            END

                        WHEN pp.priceList499 IS NOT NULL
                            THEN 'Clearance'

                        WHEN pp.priceList498 IS NOT NULL
                            THEN 'Mgr Special'

                        ELSE 'N'
                    END

                ELSE 'N'
            END AS clearance,
            pp.au_primary_price,
            pp.au_fallback_price_036,
            pp.nz_primary_price,
            pp.nz_fallback_price_492,
            pp.special_price,
            pp.au_primary,
            pp.au_fallback_036,
            pp.nz_primary,
            pp.nz_fallback_492,

            fpp.future_special_price,
            fpp.future_special_price_startdate,
            fpp.future_au_primary,
            fpp.future_au_primary_startdate,
            fpp.future_au_fallback_036,
            fpp.future_au_fallback_036_startdate,
            fpp.future_nz_primary,
            fpp.future_nz_primary_startdate,
            fpp.future_nz_fallback_492,
            fpp.future_nz_fallback_492_startdate,

            future_ppr."pricePoint6IncludingGst" AS "futurePricePoint6IncludingGst",
            future_ppr."startDate" AS "futurePprStartDate"

        FROM "tEventOfferDetail" eod
        INNER JOIN "tEventOffer" eoh
            ON eod."offerId" = eoh."offerId"
           AND eod."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
            INNER JOIN "tProducts" p
            ON p."sku" = eod."sku" and p."isActive"=true
         INNER JOIN tmp_current_rrp_combo ppr
            ON ppr."sku" = eod."sku"
            AND ppr."company" = eh."company"
        LEFT JOIN tmp_future_rrp_combo future_ppr
            ON future_ppr."sku" = eod."sku"
            AND future_ppr."company" = eh."company"

        INNER JOIN "tConfig" config
            ON config."configkey" = eh."channel"
           AND config."country" = eh."country"
           AND config."configtype" = 'SalesType'
        LEFT JOIN tmp_pivoted_prices_combomultibuybxgy pp ON pp."sku" = eod."sku" AND pp."country" = eh."country" AND pp."company" = eh."company"
        LEFT JOIN tmp_future_pivoted_prices_combomultibuybxgy fpp ON fpp."sku" = eod."sku" AND fpp."country" = eh."country" AND fpp."company" = eh."company"
         LEFT JOIN tmp_inventory_soh_combo inv
            ON inv."sku" = eod."sku"
            AND inv."company" = eh."company"
         LEFT JOIN "tSalesY1" s
            ON s."sku" = eod."sku"
           AND s."company" = eh."company"
           AND s."salesType" = config."configvalue" ->> 'channel'
        LEFT JOIN "tRegionalAreaGroupAllocation" rag
             on rag."allocationGroup"='DEFAULT'
             AND rag."country" = eh."country"
        WHERE eoh."OfferTypeId" IN (4)
        AND eh."status" IN ('Open', 'Locked')
    ),

    "baseRrpCalculation_MultiBuy" AS (
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
                END AS base_rrp_price,
            -- Future price-list waterfall result (special -> primary -> fallback),
            -- computed independently of source so it can be compared against the
            -- future PPR pricePoint6 result below and the earlier date can win.
            CASE
                WHEN d."country" = 'AU' THEN
                    COALESCE(d.future_special_price, d.future_au_primary, d.future_au_fallback_036)
                WHEN d."country" = 'NZ' THEN
                    COALESCE(d.future_special_price, d.future_nz_primary, d.future_nz_fallback_492)
            END AS future_pricelist_rrp,
            -- The startDate belonging to whichever tier future_pricelist_rrp actually resolved
            -- to above -- mirrors that COALESCE exactly so the date always matches the selected
            -- price, not just whichever tier happens to have the earliest date.
            CASE
                WHEN d."country" = 'AU' THEN
                    CASE
                        WHEN d.future_special_price IS NOT NULL THEN d.future_special_price_startdate
                        WHEN d.future_au_primary IS NOT NULL THEN d.future_au_primary_startdate
                        WHEN d.future_au_fallback_036 IS NOT NULL THEN d.future_au_fallback_036_startdate
                    END
                WHEN d."country" = 'NZ' THEN
                    CASE
                        WHEN d.future_special_price IS NOT NULL THEN d.future_special_price_startdate
                        WHEN d.future_nz_primary IS NOT NULL THEN d.future_nz_primary_startdate
                        WHEN d.future_nz_fallback_492 IS NOT NULL THEN d.future_nz_fallback_492_startdate
                    END
            END AS future_pricelist_start_date,
            -- Future PPR pricePoint6 result, rounded the same way as base_rrp_price's fallback.
            CASE
                WHEN d."futurePricePoint6IncludingGst" IS NULL THEN NULL
                ELSE
                    ROUND(
                        CASE
                            WHEN (ROUND(d."futurePricePoint6IncludingGst", 2)) < 1 THEN
                                CEILING((ROUND(d."futurePricePoint6IncludingGst", 2)) * 10) / 10.0
                            WHEN (ROUND(d."futurePricePoint6IncludingGst", 2)) < 10 THEN
                                CASE WHEN ((ROUND(d."futurePricePoint6IncludingGst", 2)) - FLOOR(ROUND(d."futurePricePoint6IncludingGst", 2))) > 0.5
                                     THEN CEILING(ROUND(d."futurePricePoint6IncludingGst", 2))
                                     ELSE FLOOR(ROUND(d."futurePricePoint6IncludingGst", 2))
                                END
                            ELSE CEILING(ROUND(d."futurePricePoint6IncludingGst", 2))
                        END, 2
                    )
            END AS future_ppr_rrp
        FROM updateEventOfferDtlForMultiBuy d
    ),
    "baseRrpCalculation_MultiBuyResolved" AS (
        SELECT
            d.*,
            CASE
                WHEN d.future_pricelist_rrp IS NOT NULL
                     AND (d."futurePprStartDate" IS NULL OR d.future_pricelist_start_date <= d."futurePprStartDate")
                THEN d.future_pricelist_rrp
                WHEN d.future_ppr_rrp IS NOT NULL
                THEN d.future_ppr_rrp
                ELSE d.future_pricelist_rrp
            END AS future_rrp_price,
            CASE
                WHEN d.future_pricelist_rrp IS NOT NULL
                     AND (d."futurePprStartDate" IS NULL OR d.future_pricelist_start_date <= d."futurePprStartDate")
                THEN d.future_pricelist_start_date
                WHEN d.future_ppr_rrp IS NOT NULL
                THEN d."futurePprStartDate"
                ELSE d.future_pricelist_start_date
            END AS future_rrp_effective_date
        FROM "baseRrpCalculation_MultiBuy" d
    ),

    calculationsForEventOfferForMultiBuy AS (
        SELECT
            d.*,
            d.base_rrp_price AS new_everydayPriceGst,
            CASE WHEN d.clearance NOT LIKE 'N' THEN d.base_rrp_price
                 ELSE d."advertisedPriceGst"
            END AS new_advertisedPriceGst,
            CASE WHEN d.clearance NOT LIKE 'N' THEN ROUND(d.base_rrp_price / (1 + COALESCE(d.gst_value, 0)),2)
                 ELSE ROUND((d."advertisedPriceGst") / (1 + COALESCE(d.gst_value, 0)),2)
            END AS new_advertisedPrice,
            ROUND(d."nationalAvgCost",2) as natAvgCost
        FROM "baseRrpCalculation_MultiBuyResolved" d
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
        "clearanceIndicator" = c.clearance,
        "stockOnHandStore" = c.sohStore,
        "stockOnHandDC"    = c.sohDc,
        "LatestEffectiveCost" = ROUND(COALESCE(c."vendorCostPerEach",0),2),
        "categoryCost"        = COALESCE(c.natAvgCost, 0),
       "forecastCost"=Round(ROUND(COALESCE(c."vendorCostPerEach",0),2)* e."categoryforecast",2),
        "forecastSales"=Round(e."categoryforecast"*ROUND(c.new_advertisedPriceGst,2),2),"everydayExtendedUnitCost"  = ROUND(c.calc_units) * COALESCE(c.natAvgCost, 0),
        "everydayExtendedUnitSales" = ROUND(c.calc_units )* c.new_everydayPriceGst,

        "extendedAdvertisedPrice" = ROUND(c.calc_units )* COALESCE( c.new_advertisedPriceGst, 0),
        "everydayCost" = COALESCE(c.natAvgCost, 0),
        "futureEdPrice" = c.future_rrp_price,
        "futureEdEffectiveDate" = c.future_rrp_effective_date,
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
    FROM calculationsForEventOfferForMultiBuy c
    WHERE e."sku" = c."sku"
      AND e."offerNo" = c."offerNo"
      AND e."offerId" = c."offerId"
      AND c."OfferTypeId" IN (4);
    RAISE NOTICE '[%] END   UPDATE tEventOfferDetail | offerType=MultiBuy | offerTypeId=4', clock_timestamp();

--===============================================================================================================
-- UPDATE tEventOffer For Combo
--===============================================================================================================

RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=Combo | offerTypeId=3', clock_timestamp();
WITH EventOfferDtlSummaryForCombo AS (
    SELECT
        d."offerId",
        d."offerNo",
        d."eventId",
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
        ROUND(SUM((COALESCE(d."LatestEffectiveCost", 0) * (COALESCE(d."scanSupport%", 0)/100) * COALESCE(d."categoryforecast", 0))),2) AS "totalScanSupport%"

    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId"
        AND d."eventId" = o."eventId"
        AND d."offerNo" = o."offerNumber"
    INNER JOIN public."tEvent" ev
        ON o."eventId" = ev."eventId"
    WHERE ev."status" IN ('Open', 'Locked')
      AND (o."OfferTypeId" IN (3))
      AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."offerNo",d."eventId",d."gst",o."offerNumber",d."clearanceIndicator"
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
FROM EventOfferDtlSummaryForCombo s
WHERE o."offerId" = s."offerId"
  AND o."offerNumber" = s."offerNo"
  AND o."eventId" = s."eventId";
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=Combo | offerTypeId=3', clock_timestamp();

 RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=Combo | offerTypeId=3', clock_timestamp();
 WITH ComboSavePercent AS (
      SELECT
          d."offerId",
          d."eventId",
          ROUND(
              SUM(COALESCE(d."calculatedSaveValue", 0)) /
              (SUM(COALESCE(d."calculatedSaveValue", 0)) + SUM(COALESCE(d."advertisedPriceGst", 0))) * 100,
          2) AS "comboSavePercent"
      FROM public."tEventOfferDetail" d
      INNER JOIN public."tEventOffer" o
          ON d."offerId" = o."offerId"
          AND d."eventId" = o."eventId"
      INNER JOIN public."tEvent" ev
          ON o."eventId" = ev."eventId"
      WHERE ev."status" IN ('Open', 'Locked')
        AND (o."OfferTypeId" IN (3))
        AND (d."clearanceIndicator" LIKE 'N' OR d."clearanceIndicator" IS NULL)
        AND d."isSkuActive" = TRUE
      GROUP BY d."offerId", d."eventId"
  ),
  EventOfferDtlAdvPriceSummaryForCombo AS (
    SELECT
        d."offerId",
        d."offerNo",
        d."eventId",
        d."gst" AS gst_value,
        -- Pricing
        MIN(d."everydayPrice")                       AS "everydayPrice",
        MIN(d."everydayPriceGst")                       AS "everydayPriceGst",
        SUM(COALESCE(d."advertisedPriceGst", 0))                  AS "advPrice",
        SUM(COALESCE(d."calculatedSaveValue", 0))                 AS "saveValue"

    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId"
        AND d."eventId" = o."eventId"
        AND d."offerNo" = o."offerNumber"
    INNER JOIN public."tEvent" ev
        ON o."eventId" = ev."eventId"
    WHERE ev."status" IN ('Open', 'Locked')
      AND (o."OfferTypeId" IN (3))
       AND (d."clearanceIndicator" LIKE 'N' OR d."clearanceIndicator" IS NULL)
       AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."offerNo",d."eventId",d."gst",o."offerNumber",d."clearanceIndicator"
)
UPDATE public."tEventOffer" AS o
SET

    -- Price + savings
     "advertisedPrice" =  ROUND(s."advPrice" / (1 + s.gst_value), 2),

    "advertisedPriceGst" =  ROUND(s."advPrice", 2),
    "saveValue"             = ROUND(s."saveValue", 2),
 "savePercent"           = Round(csp."comboSavePercent",2),
    "everydayPriceGst"      = ROUND(s."everydayPriceGst", 2),
    "everydayPrice"      = ROUND(s."everydayPrice", 2)

FROM EventOfferDtlAdvPriceSummaryForCombo s
LEFT JOIN ComboSavePercent csp
      ON s."offerId" = csp."offerId"
      AND s."eventId" = csp."eventId"
WHERE o."offerId" = s."offerId"
  AND o."offerNumber" = s."offerNo"
  AND o."eventId" = s."eventId";
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=Combo | offerTypeId=3', clock_timestamp();

--===============================================================================================================
-- UPDATE tEventOffer For BXGY
--===============================================================================================================

  --EventOfferDtlSummaryForBXGY
RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=BXGY | offerTypeId=5', clock_timestamp();
WITH EventOfferDtlSummaryForBXGY AS (
    SELECT
        d."offerId",
        d."offerNo",
        d."eventId",
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
        ROUND(SUM((COALESCE(d."LatestEffectiveCost", 0) * (COALESCE(d."scanSupport%", 0)/100) * COALESCE(d."categoryforecast", 0))),2) AS "totalScanSupport%"

    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId"
        AND d."eventId" = o."eventId"
        AND d."offerNo" = o."offerNumber"
    INNER JOIN public."tEvent" ev
        ON o."eventId" = ev."eventId"
    WHERE ev."status" IN ('Open', 'Locked')
      AND (o."OfferTypeId" IN (5))
      AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."offerNo",d."eventId",d."gst",o."offerNumber",d."clearanceIndicator"
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
FROM EventOfferDtlSummaryForBXGY s
WHERE o."offerId" = s."offerId"
  AND o."offerNumber" = s."offerNo"
  AND o."eventId" = s."eventId";
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=BXGY | offerTypeId=5', clock_timestamp();

  RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=BXGY | offerTypeId=5', clock_timestamp();
  WITH EventOfferDtlAdvPriceSummaryForBXGY AS (
    SELECT
        d."offerId",
        d."offerNo",
        d."eventId",
        d."gst" AS gst_value,
        MIN(d."everydayPrice")                       AS "everydayPrice",
        MIN(d."everydayPriceGst")                       AS "everydayPriceGst",
        SUM(COALESCE(d."advertisedPriceGst", 0))                  AS "advPrice",
        SUM(COALESCE(d."calculatedSaveValue", 0))                 AS "saveValue",
        MIN(d."calculatedSavePercentage")                 AS "savePercent"

    FROM public."tEventOfferDetail" d
    INNER JOIN public."tEventOffer" o
        ON d."offerId" = o."offerId"
        AND d."eventId" = o."eventId"
        AND d."offerNo" = o."offerNumber"
    INNER JOIN public."tEvent" ev
        ON o."eventId" = ev."eventId"
    WHERE ev."status" IN ('Open', 'Locked')
      AND (o."OfferTypeId" IN (5))
       AND (d."clearanceIndicator" LIKE 'N' OR d."clearanceIndicator" IS NULL)
       AND d."isSkuActive" = TRUE
    GROUP BY d."offerId", d."offerNo",d."eventId",d."gst",o."offerNumber",d."clearanceIndicator"
)
UPDATE public."tEventOffer" AS o
SET

    -- Price + savings
     "advertisedPrice" = CASE
            WHEN (o."offerNumber" = 2)
            THEN 0
            ELSE ROUND(s."advPrice" / (1 + s.gst_value), 2)
        END,

    "advertisedPriceGst" = CASE
            WHEN (o."offerNumber" = 2)
            THEN 0
            ELSE ROUND(s."advPrice", 2)
        END,
    "saveValue"             = ROUND(s."saveValue", 2),
    "savePercent" =         ROUND(s."savePercent", 2),
    "everydayPriceGst"      = ROUND(s."everydayPriceGst", 2),
    "everydayPrice"      = ROUND(s."everydayPrice", 2)

FROM EventOfferDtlAdvPriceSummaryForBXGY s
WHERE o."offerId" = s."offerId"
  AND o."offerNumber" = s."offerNo"
  AND o."eventId" = s."eventId";
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=BXGY | offerTypeId=5', clock_timestamp();

  --===============================================================================================================
-- UPDATE tEventOffer For MultiBuy
--===============================================================================================================

       RAISE NOTICE '[%] START UPDATE tEventOffer | offerType=MultiBuy | offerTypeId=4', clock_timestamp();
       WITH EventOfferDtlSummaryForMultiBuy AS (
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
      AND (o."OfferTypeId" IN (4))
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
    "saveValue"             = ROUND(s."saveValue", 2) * o."requiredQuantity",
    "everydayPriceGst"      = ROUND(s."everydayPriceGst", 2),
    "everydayPrice"      = ROUND(s."everydayPrice", 2),
    "savePercent" = ROUND(s."savePercent", 2),
    "isClearance" = CASE WHEN s."clearanceIndicator" NOT LIKE 'N' THEN true ELSE false END,
    -- Supplier income (derived)
    "totalSupplierIncome"   = s."totalScanSupport$" + s."totalScanSupport%" + COALESCE(o."spacePurchase", 0)
FROM EventOfferDtlSummaryForMultiBuy s
WHERE o."offerId" = s."offerId"
  AND o."eventId" = s."eventId";
RAISE NOTICE '[%] END   UPDATE tEventOffer | offerType=MultiBuy | offerTypeId=4', clock_timestamp();

--===============================================================================================================
-- UPDATE tMudMapDetail For MultiBuy
--===============================================================================================================

-- MultiBuyOffers
  RAISE NOTICE '[%] START UPDATE tMudMapDetail | offerType=MultiBuy | offerTypeId=4', clock_timestamp();
  WITH MultiBuyOffers AS (
    SELECT
        e."eventId",
        e."offerId",
        e."offerName",
        e."offerType",
        e."OfferTypeId",
        ev."status",
        e."isClearance",
        CASE WHEN e."everydayPriceGst" <> e."advertisedPriceGst" THEN COALESCE(e."totalMultiBuyPrice", 0)
        ELSE ROUND(e."everydayPriceGst" * e."requiredQuantity",2) END AS "advertisedPrice",
        ROUND(SUM(
            CASE
                WHEN COALESCE(e."everydayPriceGst", 0) > 9999999 THEN 0
                ELSE COALESCE(e."everydayPriceGst", 0)
            END
        ),2) AS "everydayPrice",
        FLOOR(SUM(
            CASE
                WHEN COALESCE(e."saveValue", 0) > 9999999 THEN 0
                ELSE COALESCE(e."saveValue", 0)
            END
        ))  AS "saveValue",
       0 AS "savePercent",
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
    WHERE e."OfferTypeId" = 4
      AND ev."status" IN ('Open', 'Locked')
    GROUP BY
        e."eventId", e."offerId", e."offerName", e."offerType",e."OfferTypeId", ev."status",
        e."totalMultiBuyPrice", e."country",
        e."requiredQuantity", e."fromPrice", e."offerQuantity", e."freeQuantity",e."isClearance", e."everydayPriceGst",  e."advertisedPriceGst"
)
UPDATE public."tMudMapDetail" AS m
SET
    "offerName" = mb."offerName",
    "offerType" = mb."offerType",
    "offerTypeId" = mb."OfferTypeId",
    "advertisedPrice" = mb."advertisedPrice",
    "everydayPrice" = COALESCE(mb."everydayPrice", m."everydayPrice"),
    "savePercent" = mb."savePercent",
    "saveValue" = mb."saveValue",
    clearance = mb."isClearance",
    new = mb.new,
    loyality = mb.loyality,
    "eventOfferId" = mb."offerId",
    country = mb.country,
    "requiredQuantity" = mb."RequiredQuantity",
    "fromPrice" = mb."fromPrice",
    "purchaseQuantity" = mb."PurchaseQuantity",
    "freeQuantity" = mb."FreeQuantity"
FROM MultiBuyOffers AS mb
WHERE m."eventId" = mb."eventId"
  AND m."eventOfferId" = mb."offerId";
RAISE NOTICE '[%] END   UPDATE tMudMapDetail | offerType=MultiBuy | offerTypeId=4', clock_timestamp();

--===============================================================================================================
-- UPDATE tMudMapDetail For BXGY
--===============================================================================================================

-- BuyXGetYOffers
RAISE NOTICE '[%] START UPDATE tMudMapDetail | offerType=BXGY | offerTypeId=5', clock_timestamp();
WITH BuyXGetYOffers AS (
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
                    ELSE COALESCE(e."savePercent", 0)
                END
            ) < 5 THEN 0
            ELSE FLOOR(
                SUM(
                    CASE
                        WHEN COALESCE(e."savePercent", 0) > 9999999 THEN 0
                        ELSE COALESCE(e."savePercent", 0)
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
    WHERE e."OfferTypeId" = 5 and e."offerNumber"=1
      AND ev."status" IN ('Open', 'Locked')
    GROUP BY
        e."eventId", e."offerId", e."offerName", e."offerType", e."OfferTypeId", ev."status",
        e."country", e."requiredQuantity", e."fromPrice", e."offerQuantity", e."freeQuantity"
)
UPDATE public."tMudMapDetail" AS m
SET
    "offerName" = b."offerName",
    "offerType" = b."offerType",
    "offerTypeId" = b."OfferTypeId",
    "advertisedPrice" = b."advertisedPrice",
    "savePercent" = b."savePercent",
    "saveValue" = b."saveValue",
    clearance = b.clearance,
    new = b.new,
    loyality = b.loyality,
    "eventOfferId" = b."offerId",
    country = b.country,
    "requiredQuantity" = b."RequiredQuantity",
    "fromPrice" = b."fromPrice",
    "purchaseQuantity" = b."PurchaseQuantity",
    "freeQuantity" = b."FreeQuantity"
FROM BuyXGetYOffers AS b
WHERE m."eventId" = b."eventId"
  and  m."eventOfferId" = b."offerId";
RAISE NOTICE '[%] END   UPDATE tMudMapDetail | offerType=BXGY | offerTypeId=5', clock_timestamp();

--===============================================================================================================
-- UPDATE tMudMapDetail For Combo
--===============================================================================================================

 RAISE NOTICE '[%] START UPDATE tMudMapDetail | offerType=Combo | offerTypeId=3', clock_timestamp();
 WITH ComboOffers AS (
    SELECT
        e."eventId",
        e."offerId",
        e."offerName",
        e."offerType",
        e."OfferTypeId",
        ev."status",
        ROUND(SUM(CASE
                WHEN COALESCE(e."everydayPriceGst", 0) > 9999999 THEN 0
                ELSE ROUND(COALESCE(e."everydayPriceGst", 0),2)
            END), 2) AS "everydayPrice",
            ROUND(SUM(CASE
                WHEN COALESCE(e."advertisedPriceGst", 0) > 9999999 THEN 0
                ELSE ROUND(COALESCE(e."advertisedPriceGst", 0),2)
            END), 2) AS "advertisedPrice",
        SUM(
            CASE
                WHEN COALESCE(e."saveValue", 0) > 9999999 THEN 0
                ELSE FLOOR(COALESCE(e."saveValue", 0))
            END
        ) AS "saveValue",
        CASE
            WHEN MIN(
                CASE
                    WHEN COALESCE(e."savePercent", 0) > 9999999 THEN 0
                    ELSE FLOOR(COALESCE(e."savePercent", 0))
                END
            ) < 5 THEN 0
            ELSE FLOOR(
                MIN(
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
    WHERE e."OfferTypeId" = 3
      AND ev."status" IN ('Open', 'Locked')
    GROUP BY
        e."eventId", e."offerId", e."offerName", e."offerType", e."OfferTypeId",ev."status",
         e."country",
        e."requiredQuantity", e."fromPrice", e."offerQuantity", e."freeQuantity"
)
UPDATE public."tMudMapDetail" AS m
SET
    "offerName" = c."offerName",
    "offerType" = c."offerType",
    "offerTypeId" = c."OfferTypeId",
    "advertisedPrice" = c."advertisedPrice",
    "everydayPrice" = COALESCE(c."everydayPrice", m."everydayPrice"),
    "savePercent" = c."savePercent",
    "saveValue" = c."saveValue",
    clearance = c.clearance,
    new = c.new,
    loyality = c.loyality,
    "eventOfferId" = c."offerId",
    country = c.country,
    "requiredQuantity" = c."RequiredQuantity",
    "fromPrice" = c."fromPrice",
    "purchaseQuantity" = c."PurchaseQuantity",
    "freeQuantity" = c."FreeQuantity"
FROM ComboOffers AS c
WHERE m."eventId" = c."eventId"
  AND m."eventOfferId" = c."offerId";
RAISE NOTICE '[%] END   UPDATE tMudMapDetail | offerType=Combo | offerTypeId=3', clock_timestamp();

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

