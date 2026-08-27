-- PROCEDURE: public.sp_update_lecost_natavgcost(integer, integer)

-- DROP PROCEDURE IF EXISTS public.sp_update_lecost_natavgcost(integer, integer);

CREATE OR REPLACE PROCEDURE public.sp_update_lecost_natavgcost(
	IN p_offerid integer,
	IN p_offerno integer,
	OUT p_lowestedprice numeric)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_gst numeric;
    v_startdate date;
    v_enddate date;
    v_country text;
    v_channel text;
    v_eventChannel text;
    v_company text;
    v_offerTypeId integer;
BEGIN
      ------------------------------------------------------------------
    SELECT
        eh."startDate",
        eh."endDate",
        eh."country",
        eh."channel",
        eoh."OfferTypeId",
        eh."company"
    INTO
        v_startdate,
        v_enddate,
        v_country,
        v_eventChannel,
		v_offerTypeId,
        v_company
    FROM "tEventOffer" eoh
    JOIN "tEvent" eh ON eh."eventId" = eoh."eventId"
    WHERE eoh."offerId" = p_offerid
      AND eoh."offerNumber" = p_offerno
      AND eh."status" IN ('Open', 'Locked')
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
 
    SELECT (config."configvalue" ->> 'channel')
    INTO v_channel
    FROM "tConfig" config
    WHERE config."configkey" = v_eventChannel
   AND config."country" = v_country
   AND config."configtype" = 'SalesType';
    ----------------------------------------------------------------------
    -- STEP 1 -> UPDATE COSTS IN tEventOfferDetail
    ----------------------------------------------------------------------
    WITH "offerSkus" AS (
        SELECT "sku" FROM "tEventOfferDetail"
        WHERE "offerId" = p_offerId AND "offerNo" = p_offerNo
    ),

    "pricelistDetail" AS (
        SELECT
            pld."sku",
            pld."priceList",
            pld."priceListPrice",
            pld."startDate",
            pld."country",
            ROW_NUMBER() OVER (
                PARTITION BY pld."sku",pld."country",
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
          AND pld.company = v_company
          AND pld."startDate" <= CURRENT_DATE
          AND pld."sku" IN (SELECT "sku" FROM "offerSkus")
    ),

    "pivoted_prices" AS (
        SELECT
            "sku","country",
            MAX(CASE WHEN "priceList" = '050' AND group_rn = 1 THEN "priceListPrice" END) AS priceList50,
            MAX(CASE WHEN "priceList" = '184' AND group_rn = 1 THEN "priceListPrice" END) AS priceList184,
            MAX(CASE WHEN "priceList" = '499' AND group_rn = 1 THEN "priceListPrice" END) AS priceList499,
            MAX(CASE WHEN "priceList" = '498' AND group_rn = 1 THEN "priceListPrice" END) AS priceList498,
            MAX(CASE WHEN "priceList" IN ('390','419','824','343','446','241') AND group_rn = 1 THEN "priceListPrice" END) AS au_primary_price,
            MAX(CASE WHEN "priceList" = '036' AND group_rn = 1 THEN "priceListPrice" END) AS au_fallback_price_036,
            MAX(CASE WHEN "priceList" IN ('371','274','211','044','134','021') AND group_rn = 1 THEN "priceListPrice" END) AS nz_primary_price,
            MAX(CASE WHEN "priceList" = '492' AND group_rn = 1 THEN "priceListPrice" END) AS nz_fallback_price_492
        FROM "pricelistDetail"
        WHERE group_rn = 1
        GROUP BY "sku","country"
    ),

    "futurePricelistDetail" AS (
        SELECT
            pld."sku",
            pld."priceList",
            pld."priceListPrice",
            pld."startDate",
            pld."country",
            ROW_NUMBER() OVER (
                PARTITION BY pld."sku",pld."country",
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
          AND pld.company = v_company
          AND pld."startDate" > CURRENT_DATE
          AND pld."sku" IN (SELECT "sku" FROM "offerSkus")
    ),

    "future_pivoted_prices" AS (
        -- Each tier (clearance/184, primary codes, fallback, etc.) tracks its OWN
        -- winning row's startDate alongside its price, so whichever tier the
        -- waterfall in baseRrpCalculation actually selects, its matching date
        -- comes along with it -- a single MIN(startDate) across all tiers would
        -- report a date belonging to a price that wasn't the one selected.
        SELECT
            "sku","country",
            MAX(CASE WHEN "priceList" = '050' AND group_rn = 1 THEN "priceListPrice" END) AS priceList50,
            MAX(CASE WHEN "priceList" = '050' AND group_rn = 1 THEN "startDate" END) AS "priceList50StartDate",
            MAX(CASE WHEN "priceList" = '184' AND group_rn = 1 THEN "priceListPrice" END) AS priceList184,
            MAX(CASE WHEN "priceList" = '184' AND group_rn = 1 THEN "startDate" END) AS "priceList184StartDate",
            MAX(CASE WHEN "priceList" = '499' AND group_rn = 1 THEN "priceListPrice" END) AS priceList499,
            MAX(CASE WHEN "priceList" = '499' AND group_rn = 1 THEN "startDate" END) AS "priceList499StartDate",
            MAX(CASE WHEN "priceList" = '498' AND group_rn = 1 THEN "priceListPrice" END) AS priceList498,
            MAX(CASE WHEN "priceList" = '498' AND group_rn = 1 THEN "startDate" END) AS "priceList498StartDate",
            MAX(CASE WHEN "priceList" IN ('390','419','824','343','446','241') AND group_rn = 1 THEN "priceListPrice" END) AS au_primary_price,
            MAX(CASE WHEN "priceList" IN ('390','419','824','343','446','241') AND group_rn = 1 THEN "startDate" END) AS "auPrimaryStartDate",
            MAX(CASE WHEN "priceList" = '036' AND group_rn = 1 THEN "priceListPrice" END) AS au_fallback_price_036,
            MAX(CASE WHEN "priceList" = '036' AND group_rn = 1 THEN "startDate" END) AS "auFallback036StartDate",
            MAX(CASE WHEN "priceList" IN ('371','274','211','044','134','021') AND group_rn = 1 THEN "priceListPrice" END) AS nz_primary_price,
            MAX(CASE WHEN "priceList" IN ('371','274','211','044','134','021') AND group_rn = 1 THEN "startDate" END) AS "nzPrimaryStartDate",
            MAX(CASE WHEN "priceList" = '492' AND group_rn = 1 THEN "priceListPrice" END) AS nz_fallback_price_492,
            MAX(CASE WHEN "priceList" = '492' AND group_rn = 1 THEN "startDate" END) AS "nzFallback492StartDate"
        FROM "futurePricelistDetail"
        WHERE group_rn = 1
        GROUP BY "sku","country"
    ),

    "future_ppr" AS (
       SELECT
        ppr_future."sku",
        ppr_future."company",
        ppr_future."pricePoint6IncludingGst",
        ppr_future."startDate"
    FROM "tPriceProductRules" ppr_future
    WHERE ppr_future."startDate" > CURRENT_DATE
      AND ppr_future."isActive" = TRUE
      AND ppr_future."company" = v_company
      AND ppr_future."sku" IN (SELECT "sku" FROM "offerSkus")
    ),
 
    data AS (
        SELECT
            d."sku",
            d."offerNo",
            d."offerId",
            s."averageMonthlySales",
            (COALESCE(s."averageMonthlySales", 0) / 30.0) *
            ((COALESCE(eoh."endDate", eh."endDate") -
              COALESCE(eoh."startDate", eh."startDate")) + 1) AS calc_units,
 
            v_channel AS "salesType",
            v_gst AS gst_value,
 
            ppr."pricePoint6",
            ppr."pricePoint6IncludingGst",
            future_ppr."pricePoint6IncludingGst" AS "futurePricePoint6IncludingGst",
            future_ppr."startDate" AS "futurePprStartDate",

            p."vendorCostPerEach",
            p."nationalAvgCost",
            p."isActive",
            p."clearance",
            eh."country",
            COALESCE(SUM(CASE WHEN UPPER(inv."locationType") = 'STORE' THEN inv."onHand" END), 0) AS sohStore,
            COALESCE(SUM(CASE WHEN UPPER(inv."locationType") <> 'STORE' THEN inv."onHand" END), 0) AS sohDc,

            pp.priceList50,
            pp.priceList184,
            pp.priceList499,
            pp.priceList498,
            pp.au_primary_price,
            pp.au_fallback_price_036,
            pp.nz_primary_price,
            pp.nz_fallback_price_492,

            fpp.priceList50 AS "futurePriceList50",
            fpp."priceList50StartDate" AS "futurePriceList50StartDate",
            fpp.priceList184 AS "futurePriceList184",
            fpp."priceList184StartDate" AS "futurePriceList184StartDate",
            fpp.priceList499 AS "futurePriceList499",
            fpp."priceList499StartDate" AS "futurePriceList499StartDate",
            fpp.priceList498 AS "futurePriceList498",
            fpp."priceList498StartDate" AS "futurePriceList498StartDate",
            fpp.au_primary_price AS "futureAuPrimaryPrice",
            fpp."auPrimaryStartDate" AS "futureAuPrimaryStartDate",
            fpp.au_fallback_price_036 AS "futureAuFallbackPrice036",
            fpp."auFallback036StartDate" AS "futureAuFallback036StartDate",
            fpp.nz_primary_price AS "futureNzPrimaryPrice",
            fpp."nzPrimaryStartDate" AS "futureNzPrimaryStartDate",
            fpp.nz_fallback_price_492 AS "futureNzFallbackPrice492",
            fpp."nzFallback492StartDate" AS "futureNzFallback492StartDate"

        FROM "tEventOfferDetail" d
        INNER JOIN "tEventOffer" eoh
            ON d."offerId" = eoh."offerId"
           AND d."offerNo" = eoh."offerNumber"
        INNER JOIN "tEvent" eh
            ON eh."eventId" = eoh."eventId"
            INNER JOIN "tProducts" p
            ON p."sku" = d."sku"
            AND p."isActive" = TRUE
        INNER JOIN "tPriceProductRules" ppr
            ON ppr."sku" = d."sku"
            AND ppr."company" = eh."company"
            and ppr."startDate"<=CURRENT_DATE and  ppr."endDate">=CURRENT_DATE
            and ppr."isActive" = TRUE
        LEFT JOIN "future_ppr" future_ppr
            ON future_ppr."sku" = d."sku"
            AND future_ppr."company" = eh."company"
        LEFT JOIN "pivoted_prices" pp ON pp."sku" = d."sku" and pp."country"=eh."country"
        LEFT JOIN "future_pivoted_prices" fpp ON fpp."sku" = d."sku" and fpp."country"=eh."country"
        LEFT JOIN "tSalesY1" s
            ON s."sku" = d."sku"
           AND s."company" = eh."company"
           AND s."salesType" = v_channel
        LEFT JOIN "tInventory" inv
            ON inv."sku" = d."sku"
            and inv."company" in (eh."company",'12','52')
        WHERE d."offerId" = p_offerId
          AND d."offerNo" = p_offerNo
          AND d."isSkuActive" = TRUE
          AND eh."status" IN ('Open', 'Locked')
        GROUP BY
            d."sku", d."offerNo", d."offerId",
            eoh."offerId", s."averageMonthlySales",
            eoh."endDate", eoh."startDate",
            eh."endDate", eh."startDate",
            v_channel, v_gst,
            ppr."pricePoint6",
            ppr."pricePoint6IncludingGst",
            future_ppr."pricePoint6IncludingGst",
            future_ppr."startDate",
            p."vendorCostPerEach", p."nationalAvgCost",
            p."isActive",
            p."clearance",
            eh."country",
            pp.priceList50,
            pp.priceList184,
            pp.priceList499,
            pp.priceList498,
            pp.au_primary_price,
            pp.au_fallback_price_036,
            pp.nz_primary_price,
            pp.nz_fallback_price_492,
            fpp.priceList50,
            fpp."priceList50StartDate",
            fpp.priceList184,
            fpp."priceList184StartDate",
            fpp.priceList499,
            fpp."priceList499StartDate",
            fpp.priceList498,
            fpp."priceList498StartDate",
            fpp.au_primary_price,
            fpp."auPrimaryStartDate",
            fpp.au_fallback_price_036,
            fpp."auFallback036StartDate",
            fpp.nz_primary_price,
            fpp."nzPrimaryStartDate",
            fpp.nz_fallback_price_492,
            fpp."nzFallback492StartDate"
    ),

    "baseRrpCalculation" AS (
        SELECT
            d.*,
            CASE
                -- Special pricing: price lists 050 and/or 184, applied to every row (no clearance gate).
                -- RRP per country: special (LEAST) -> primary -> fallback -> pricePoint6 (rounded)
                WHEN d."country" = 'AU' THEN
                    CASE
                        WHEN LEAST(d.priceList50, d.priceList184) IS NOT NULL THEN
                            LEAST(d.priceList50, d.priceList184)
                        WHEN d.au_primary_price IS NOT NULL THEN
                            d.au_primary_price
                        WHEN d.au_fallback_price_036 IS NOT NULL THEN
                            d.au_fallback_price_036
                        ELSE
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
                    END
                WHEN d."country" = 'NZ' THEN
                    CASE
                        WHEN LEAST(d.priceList499, d.priceList498) IS NOT NULL THEN
                            LEAST(d.priceList499, d.priceList498)
                        WHEN d.nz_primary_price IS NOT NULL THEN
                            d.nz_primary_price
                        WHEN d.nz_fallback_price_492 IS NOT NULL THEN
                            d.nz_fallback_price_492
                        ELSE
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
                    END
                END AS base_rrp_price,
            -- Future price-list waterfall result (special -> primary -> fallback),
            -- computed independently of source so it can be compared against the
            -- future PPR pricePoint6 result below and the earlier date can win.
            CASE
                WHEN d."country" = 'AU' THEN
                    COALESCE(LEAST(d."futurePriceList50", d."futurePriceList184"), d."futureAuPrimaryPrice", d."futureAuFallbackPrice036")
                WHEN d."country" = 'NZ' THEN
                    COALESCE(LEAST(d."futurePriceList499", d."futurePriceList498"), d."futureNzPrimaryPrice", d."futureNzFallbackPrice492")
            END AS future_pricelist_rrp,
            -- The startDate belonging to whichever tier/row future_pricelist_rrp
            -- actually resolved to above -- mirrors that CASE exactly so the date
            -- always matches the selected price, not just whichever tier happens
            -- to have the earliest date.
            CASE
                WHEN d."country" = 'AU' THEN
                    CASE
                        WHEN LEAST(d."futurePriceList50", d."futurePriceList184") IS NOT NULL THEN
                            CASE
                                WHEN d."futurePriceList50" IS NULL THEN d."futurePriceList184StartDate"
                                WHEN d."futurePriceList184" IS NULL THEN d."futurePriceList50StartDate"
                                WHEN d."futurePriceList50" <= d."futurePriceList184" THEN d."futurePriceList50StartDate"
                                ELSE d."futurePriceList184StartDate"
                            END
                        WHEN d."futureAuPrimaryPrice" IS NOT NULL THEN d."futureAuPrimaryStartDate"
                        WHEN d."futureAuFallbackPrice036" IS NOT NULL THEN d."futureAuFallback036StartDate"
                    END
                WHEN d."country" = 'NZ' THEN
                    CASE
                        WHEN LEAST(d."futurePriceList499", d."futurePriceList498") IS NOT NULL THEN
                            CASE
                                WHEN d."futurePriceList499" IS NULL THEN d."futurePriceList498StartDate"
                                WHEN d."futurePriceList498" IS NULL THEN d."futurePriceList499StartDate"
                                WHEN d."futurePriceList499" <= d."futurePriceList498" THEN d."futurePriceList499StartDate"
                                ELSE d."futurePriceList498StartDate"
                            END
                        WHEN d."futureNzPrimaryPrice" IS NOT NULL THEN d."futureNzPrimaryStartDate"
                        WHEN d."futureNzFallbackPrice492" IS NOT NULL THEN d."futureNzFallback492StartDate"
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
        FROM data d
    ),
    "futureRrpResolved" AS (
        SELECT
            d.*,
            -- Prefer the source with the earlier startDate; if only one source
            -- exists (or the price-list waterfall found no match), use the other.
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
        FROM "baseRrpCalculation" d
    )
    UPDATE "tEventOfferDetail" e
    SET
        "everydayUnits" = ROUND(d.calc_units),
 
        "everydayPrice" = ROUND(d.base_rrp_price / (1 + COALESCE(d.gst_value, 0)),2),
 
        "everydayPriceGst" = ROUND(d.base_rrp_price,2),
 
        "everydayPriceGstSys" = ROUND(d.base_rrp_price,2),
 
        "stockOnHandStore" =  d.sohStore ,
        "stockOnHandDC"    = d.sohDc ,
        "gst" = d.gst_value ,
        "LatestEffectiveCost"      = ROUND(COALESCE(d."vendorCostPerEach", 0),2) ,
        "nationalAverageCost"      = ROUND(COALESCE(d."nationalAvgCost", 0),2) ,
        "categoryCost"             = ROUND(COALESCE(d."nationalAvgCost", 0),2) ,
 
        "everydayExtendedUnitCost"  = ROUND(d.calc_units) * ROUND(COALESCE(d."nationalAvgCost", 0),2) ,
        "everydayExtendedUnitSales" = ROUND(d.calc_units) * ROUND(d.base_rrp_price,2) ,
 
        "extendedAdvertisedPrice" = ROUND(d.calc_units) * ROUND(COALESCE(e."advertisedPrice", 0),2) ,
        "everydayCost" = ROUND(COALESCE(d."nationalAvgCost", 0),2) ,
        "futureEdPrice" = d.future_rrp_price,
        "futureEdEffectiveDate" = d.future_rrp_effective_date,
        "isCategoryForecastLocked" =
                                    CASE
                                        WHEN e."isSkuEdited" IS FALSE OR e."isSkuEdited" IS NULL
                                        THEN FALSE
                                        ELSE e."isCategoryForecastLocked"
                                    END
    FROM "futureRrpResolved" d
    WHERE e."sku" = d."sku"
      AND e."offerNo" = d."offerNo"
      AND e."offerId" = d."offerId";
 
    ----------------------------------------------------------------------
    -- STEP 2 -> UPDATE IMAGE & COPY REFERENCES
    ----------------------------------------------------------------------
    IF v_offerTypeId IN (1,3,4,5,13,17) THEN
    WITH latest_offer AS (
        SELECT
            o."imageReference",
            o."copyReference"
        FROM "tEventOffer" o
        INNER JOIN "tEventOfferDetail" d
            ON o."offerNumber" = d."offerNo"
           AND o."offerId" = d."offerId"
        INNER JOIN "tEvent" h
            ON o."eventId" = h."eventId"
        INNER JOIN "tEventOffer" curr_offer
            ON curr_offer."offerId" = p_offerId
           AND curr_offer."offerNumber" = p_offerNo
        INNER JOIN "tEvent" curr
            ON curr."eventId" = curr_offer."eventId"
        WHERE
            h."eventId" <> curr."eventId"
            AND d."sku" IN (
                SELECT "sku" FROM "tEventOfferDetail"
                WHERE "offerId" = p_offerId AND "offerNo" = p_offerNo
            )
            AND h."channel" = curr."channel"
            AND h."company" = curr."company"
            AND h."country" = curr."country"
            AND h."eventType" = curr."eventType"
            AND o."offerType" = curr_offer."offerType"
            AND h."startDate" >= CURRENT_DATE - INTERVAL '13 months'
            AND o."imageReference" IS NOT NULL
            AND o."copyReference" IS NOT NULL
        ORDER BY h."startDate" DESC
        LIMIT 1
    ),
    latest_offer_by_name AS (
        SELECT
            o."imageReference",
            o."copyReference"
        FROM "tEventOffer" o
        INNER JOIN "tEvent" h
            ON o."eventId" = h."eventId"
        INNER JOIN "tEventOffer" curr_offer
            ON curr_offer."offerId" = p_offerId
           AND curr_offer."offerNumber" = p_offerNo
        INNER JOIN "tEvent" curr
            ON curr."eventId" = curr_offer."eventId"
        WHERE
            h."channel" = curr."channel"
            AND h."company" = curr."company"
            AND h."country" = curr."country"
            AND h."eventType" = curr."eventType"
            AND o."offerType" = curr_offer."offerType"
            AND o."offerName" = curr_offer."offerName"
            AND o."offerType" IN ('COMBO', 'BUY X GET Y FREE')
            AND h."startDate" >= CURRENT_DATE - INTERVAL '13 months'
            AND o."imageReference" IS NOT NULL
            AND o."copyReference" IS NOT NULL
        ORDER BY h."startDate" DESC
        LIMIT 1
    )
    UPDATE "tEventOffer" o
    SET
        "imageReference" = COALESCE(lo."imageReference", lon."imageReference"),
        "copyReference"  = COALESCE(lo."copyReference", lon."copyReference")
    FROM latest_offer lo
    FULL JOIN latest_offer_by_name lon ON TRUE
    WHERE o."offerId" = p_offerId
      AND o."offerNumber" = p_offerNo
      AND o."OfferTypeId" IN
        (1,3,4,5,13,17);
    END IF;
 
     SELECT MIN(COALESCE("everydayPriceGst", 0))
    INTO p_lowestEdPrice
    FROM "tEventOfferDetail"
    WHERE "offerNo" = p_offerNo
      AND "offerId" = p_offerId;
 
END;
$BODY$;
