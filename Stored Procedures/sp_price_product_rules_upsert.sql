-- PROCEDURE: public.sp_price_product_rules_upsert()

-- DROP PROCEDURE IF EXISTS public.sp_price_product_rules_upsert();

CREATE OR REPLACE PROCEDURE public.sp_price_product_rules_upsert(
	)
LANGUAGE 'plpgsql'
AS $BODY$
  DECLARE
      v_total INT;
      v_deleted_infinity INT := 0;
      v_inserted INT := 0;
      v_updated INT := 0;
      -- CHANGE: Added variable to track inactive record count
      v_marked_inactive INT := 0;
      v_final_data_count INT := 0;
      v_start_time TIMESTAMPTZ := clock_timestamp() AT TIME ZONE 'Australia/Sydney';
      v_end_time TIMESTAMPTZ;
  BEGIN
      -- Log start
      INSERT INTO execution_log(job_name, status, start_time)
      VALUES ('sp_price_product_rules_upsert', 'STARTED', v_start_time);

      RAISE INFO 'Price Product Rules Upsert Started at %', v_start_time;

      -- Skip the entire process when the source temp table is empty (no action taken)
      IF EXISTS (SELECT 1 FROM public."tPriceProductRules_temp") THEN

      -- Capture whether temp holds BOTH AU and NZ before the DELETE below mutates it

      -- 1: Create indexes on temp table if not exist
      CREATE INDEX IF NOT EXISTS idx_temp_lookup
      ON public."tPriceProductRules_temp" (sku, "endDate");

      -- 2: Identify dated (non-infinity) records and select oldest endDate per key
      DROP TABLE IF EXISTS temp_dated_records;
      CREATE TEMP TABLE temp_dated_records AS
      SELECT DISTINCT ON ("supplierId", sku, company, country)
          country, "supplierId", sku, company, "startDate", "endDate",
          "priceClass1", "priceClass2", "basePrice",
          "pricePoint1", "pricePoint2", "pricePoint3", "pricePoint4", "pricePoint5", "pricePoint6"
      FROM public."tPriceProductRules_temp"
      WHERE LOWER(TRIM("endDate"::text)) != 'infinity'
      ORDER BY "supplierId", sku, company, country, "endDate" ASC;

      CREATE INDEX idx_temp_dated_sku ON temp_dated_records (sku);
      CREATE INDEX idx_temp_dated_join ON temp_dated_records (country, company, sku);
      CREATE INDEX idx_temp_dated_profile ON temp_dated_records (country, company, "priceClass1", "priceClass2");
      ANALYZE temp_dated_records;

      RAISE INFO 'Dated records (earliest non-infinity endDate per key): % rows at %', (SELECT COUNT(*) FROM temp_dated_records), NOW();

      -- 3: Identify infinity records - keep one per key
      DROP TABLE IF EXISTS temp_infinity_records;
      CREATE TEMP TABLE temp_infinity_records AS
      SELECT DISTINCT ON ("supplierId", sku, company, country)
          country, "supplierId", sku, company, "startDate", "endDate",
          "priceClass1", "priceClass2", "basePrice",
          "pricePoint1", "pricePoint2", "pricePoint3", "pricePoint4", "pricePoint5", "pricePoint6"
      FROM public."tPriceProductRules_temp"
      WHERE LOWER(TRIM("endDate"::text)) = 'infinity'
      ORDER BY "supplierId", sku, company, country;

      CREATE INDEX idx_temp_infinity_sku ON temp_infinity_records (sku);
      ANALYZE temp_infinity_records;

      RAISE INFO 'Infinity records identified (one per key): % rows at %', (SELECT COUNT(*) FROM temp_infinity_records), NOW();

      -- 4: Determine which records to process
      DROP TABLE IF EXISTS temp_records_to_process;
      CREATE TEMP TABLE temp_records_to_process AS
      SELECT * FROM temp_dated_records
      UNION ALL
      SELECT ir.*
      FROM temp_infinity_records ir
      WHERE NOT EXISTS (
          SELECT 1 FROM temp_dated_records dr
          WHERE dr.company      = ir.company
            AND dr.country      = ir.country
            AND dr."supplierId" = ir."supplierId"
            AND dr.sku          = ir.sku
      );

      CREATE INDEX idx_temp_process_sku ON temp_records_to_process (sku);
      CREATE INDEX idx_temp_process_join ON temp_records_to_process (country, company, sku);
      CREATE INDEX idx_temp_process_profile ON temp_records_to_process (country, company, "priceClass1", "priceClass2");
      ANALYZE temp_records_to_process;

      RAISE INFO 'Records to process: % rows at %', (SELECT COUNT(*) FROM temp_records_to_process), NOW();

      -- CHANGE: Mark records as inactive if they're not in today's data
      UPDATE public."tPriceProductRules"
      SET "isActive" = FALSE,
          "updatedAt" = NOW()
      WHERE "isActive" = TRUE
        AND NOT EXISTS (
            SELECT 1
            FROM temp_records_to_process t
            WHERE t.company = "tPriceProductRules".company
              AND t."supplierId" = "tPriceProductRules"."supplierId"
              AND t.country = "tPriceProductRules".country
              AND t.sku = "tPriceProductRules".sku
        );

      -- CHANGE: Get count of records marked as inactive
      GET DIAGNOSTICS v_marked_inactive = ROW_COUNT;
      RAISE INFO 'Marked % existing records as inactive at %', v_marked_inactive, NOW();

      -- 5: Clean up temp table
      DELETE FROM public."tPriceProductRules_temp" t
      WHERE LOWER(TRIM(t."endDate"::text)) = 'infinity'
        AND EXISTS (
            SELECT 1
            FROM temp_dated_records d
            WHERE d.company      = t.company
              AND d.country      = t.country
              AND d."supplierId" = t."supplierId"
              AND d.sku          = t.sku
        );

      GET DIAGNOSTICS v_deleted_infinity = ROW_COUNT;
      RAISE INFO 'Deleted infinity records from temp table: % rows at %', v_deleted_infinity, NOW();

      -- 6: Materialize price_lists - INCLUDES BOTH AU AND NZ PRICE LISTS
      --    FIXED: Added missing NZ price lists (PL134, PL211)
      DROP TABLE IF EXISTS temp_price_lists;
      CREATE TEMP TABLE temp_price_lists AS
      SELECT
          pld.country, pld.company, pld.sku,
          -- AU Price Lists (companies: 11, 61, 75, 81, 83)
          MAX(CASE WHEN pld."priceList" = '036' AND pld.company = '11' THEN pld."priceListPrice" END) AS pl_036,
          MIN(CASE WHEN pld."priceList" IN ('050','051') THEN pld."priceListPrice" END) AS pl_050_051,
          MAX(CASE WHEN pld."priceList" = '076' AND pld.company = '11' THEN pld."priceListPrice" END) AS pl_076,
          MAX(CASE WHEN pld."priceList" = '121' AND pld.company = '11' THEN pld."priceListPrice" END) AS pl_121_au,
          MAX(CASE WHEN pld."priceList" = '184' AND pld.company = '11' THEN pld."priceListPrice" END) AS pl_184,
          MAX(CASE WHEN pld."priceList" = '191' AND pld.company = '11' THEN pld."priceListPrice" END) AS pl_191,
          MAX(CASE WHEN pld."priceList" = '343' AND pld.company = '11' THEN pld."priceListPrice" END) AS pl_343,
          MAX(CASE WHEN pld."priceList" = '419' AND pld.company = '11' THEN pld."priceListPrice" END) AS pl_419,
          MAX(CASE WHEN pld."priceList" = '446' AND pld.company = '11' THEN pld."priceListPrice" END) AS pl_446,
          MAX(CASE WHEN pld."priceList" = '017' AND pld.company IN ('81','83') THEN pld."priceListPrice" END) AS pl_017,
          MIN(CASE WHEN pld."priceList" IN ('300','824') AND pld.company='11' THEN pld."priceListPrice" END) AS pl_300_824_co11,
          MIN(CASE WHEN pld."priceList"='300' AND pld.company='83' THEN pld."priceListPrice" END) AS pl_300_co83,
          MIN(CASE WHEN pld."priceList"='396' AND pld.company='83' THEN pld."priceListPrice" END) AS pl_396,
          MIN(CASE WHEN pld."priceList" IN ('541','547') AND pld.company='83' THEN pld."priceListPrice" END) AS pl_541_547,
          MAX(CASE WHEN pld."priceList"='390' AND pld.company IN ('11','81') THEN pld."priceListPrice" END) AS pl_390_au,
          -- NZ Price Lists (companies: 50, 51, 85)
          MAX(CASE WHEN pld."priceList" = '497' AND pld.company='50' THEN pld."priceListPrice" END) AS pl_497,
          MIN(CASE WHEN pld."priceList" = '499' AND pld.company IN ('50','51','85') THEN pld."priceListPrice" END) AS pl_499,
          MAX(CASE WHEN pld."priceList" = '021' AND pld.company IN ('50','51') THEN pld."priceListPrice" END) AS pl_021,
          MAX(CASE WHEN pld."priceList" = '496' AND pld.company='50' THEN pld."priceListPrice" END) AS pl_496,
          MIN(CASE WHEN pld."priceList" = '498' AND pld.company='50' THEN pld."priceListPrice" END) AS pl_498,
          MAX(CASE WHEN pld."priceList" = '044' AND pld.company IN ('50','51') THEN pld."priceListPrice" END) AS pl_044,
          MAX(CASE WHEN pld."priceList" = '134' AND pld.company IN ('50','51') THEN pld."priceListPrice" END) AS pl_134,
          MAX(CASE WHEN pld."priceList" = '211' AND pld.company IN ('50','51') THEN pld."priceListPrice" END) AS pl_211,
          MAX(CASE WHEN pld."priceList" = '121' AND pld.company IN ('50','51') THEN pld."priceListPrice" END) AS pl_121_nz,
          MAX(CASE WHEN pld."priceList" = '390' AND pld.company='50' THEN pld."priceListPrice" END) AS pl_390_nz
      FROM public."tPriceListDetail" pld
      INNER JOIN temp_records_to_process trp
          ON trp.country = pld.country
         AND trp.company = pld.company
         AND trp.sku = pld.sku
      WHERE (
          -- All price lists with date filter
          (pld."startDate" <= CURRENT_DATE  and pld."endDate">= CURRENT_DATE
           AND pld."priceList" IN ('036','050','051','076','121','184','191','343','419','446','017',
                                   '300','824','396','541','547','390',
                                   '497','499','021','496','498','211'))
          OR
          -- PL044 and PL134 (NZ keytype tools) without date filter
          (pld."priceList" IN ('044','134') AND pld.company IN ('50','51'))
      )
      GROUP BY pld.country, pld.company, pld.sku;

      CREATE INDEX idx_temp_price_lists ON temp_price_lists (country, company, sku);
      ANALYZE temp_price_lists;

      RAISE INFO 'Price lists materialized: % rows at %', (SELECT COUNT(*) FROM temp_price_lists), NOW();

      -- 7: Materialize final_data as temp table
      DROP TABLE IF EXISTS temp_final_data;
      CREATE TEMP TABLE temp_final_data AS
      WITH gst_rates AS (
          SELECT country, (configvalue ->> 'GST')::numeric AS gst_rate
          FROM public."tConfig"
          WHERE LOWER(configtype) = 'gst'
      ),

      profile_lookup AS (
          SELECT country, company,
              "priceClass1", "priceClass2",
              "pricePointer", "percentVariation", "percentPriceAdjust"
          FROM public."tPriceProfile"
      ),

      calculated_prices AS (
          SELECT
              lr.country, lr."supplierId", lr.sku, lr.company,
              lr."startDate", lr."endDate", lr."priceClass1", lr."priceClass2",
              lr."basePrice", lr."pricePoint1", lr."pricePoint2", lr."pricePoint3",
              lr."pricePoint4", lr."pricePoint5", lr."pricePoint6",
              COALESCE(ps."pricePointer", pd."pricePointer") AS "pricePointer",
              COALESCE(ps."percentVariation", pd."percentVariation") AS "percentVariance",
              COALESCE(ps."percentPriceAdjust", pd."percentPriceAdjust") AS "percentPriceAdjustment",
              COALESCE(gst.gst_rate, 0.10) AS gst_rate,
              -- AU price lists
              pl.pl_036, pl.pl_050_051, pl.pl_076, pl.pl_121_au, pl.pl_184,
              pl.pl_191, pl.pl_343, pl.pl_419, pl.pl_446, pl.pl_017,
              pl.pl_300_824_co11, pl.pl_300_co83, pl.pl_396, pl.pl_541_547, pl.pl_390_au,
              -- NZ price lists (ADDED: pl_134, pl_211)
              pl.pl_497, pl.pl_499, pl.pl_021, pl.pl_496, pl.pl_498,
              pl.pl_044, pl.pl_134, pl.pl_211, pl.pl_121_nz, pl.pl_390_nz
          FROM temp_records_to_process lr
          LEFT JOIN profile_lookup pd
              ON pd.country = lr.country
             AND pd.company = lr.company
             AND pd."priceClass1" IS NULL
             AND pd."priceClass2" IS NULL
          LEFT JOIN profile_lookup ps
              ON ps.country = lr.country
             AND ps.company = lr.company
             AND ps."priceClass1" = lr."priceClass1"
             AND ps."priceClass2" = lr."priceClass2"
          LEFT JOIN gst_rates gst
              ON gst.country = lr.country
          LEFT JOIN temp_price_lists pl
              ON pl.country = lr.country
             AND pl.company = lr.company
             AND pl.sku = lr.sku
      ),

      price_calculations AS (
          SELECT *,
              CASE
                  WHEN "pricePointer" = 0 THEN
                      "basePrice" / (1 - (-1 * ((1.0/(1 + ("percentPriceAdjustment"/100.0))) - 1)))
                  ELSE CASE
                      WHEN "percentVariance" >= 0 THEN "pricePoint6" + ("pricePoint6" * ("percentVariance"/100.0))
                      WHEN "percentVariance" < 0 THEN "pricePoint6" + (("pricePoint5" - "pricePoint6") * ("percentVariance"/100.0))
                      ELSE "pricePoint6"
                  END
              END AS pp6_promo
          FROM calculated_prices
      ),

      gst_retail_calculations AS (
          SELECT *,
              -- DIFFERENT GST CALCULATION FOR AU VS NZ
              CASE
                  -- AU companies: Standard rounding
                  WHEN company IN ('11','61','75','81','83') THEN
                      ROUND(ROUND(pp6_promo::numeric, 2) * (1 + gst_rate), 2)
                  -- NZ companies: Subtract 0.0005 before rounding (rounds down)
                  WHEN company IN ('50','51','85') THEN
                      ROUND(ROUND(pp6_promo::numeric, 2) * (1 + gst_rate) - 0.0005, 2)
                  -- Default for other companies
                  ELSE
                      ROUND(ROUND(pp6_promo::numeric, 2) * (1 + gst_rate), 2)
              END AS pp6_gst
          FROM price_calculations
      ),

      with_retail AS (
          SELECT *,
              -- RETAIL ROUNDING: AU (11,61,75) and NZ (50,51,85) use SAME logic
              CASE
                  WHEN company IN ('11','61','75','50','51','85') THEN
                      CASE
                          -- Exact values 1 or 10
                          WHEN pp6_gst IN (1, 10) THEN pp6_gst

                          -- Values less than 1
                          WHEN pp6_gst < 1 THEN
                              CASE
                                  WHEN pp6_gst = TRUNC(pp6_gst, 1) THEN pp6_gst
                                  ELSE TRUNC(pp6_gst, 1) + 0.1
                              END

                          -- Values between 1 and 10
                          WHEN pp6_gst > 1 AND pp6_gst < 10 THEN
                              CASE
                                  WHEN (pp6_gst - FLOOR(pp6_gst)) <= 0.49 THEN FLOOR(pp6_gst)
                                  ELSE FLOOR(pp6_gst) + 1
                              END

                          -- Values >= 10
                          ELSE
                              CASE
                                  WHEN pp6_gst = FLOOR(pp6_gst) THEN pp6_gst
                                  ELSE FLOOR(pp6_gst) + 1
                              END
                      END
                  -- Other companies: no special rounding
                  ELSE pp6_gst
              END AS pp6_retail,
              -- Key type final calculation (AU ONLY)
              CASE
                  WHEN company IN ('11','81','83') THEN
                      LEAST(
                          COALESCE(pl_300_824_co11, 999999),
                          COALESCE(pl_300_co83, 999999),
                          COALESCE(pl_396, 999999),
                          COALESCE(ROUND(ROUND(pl_541_547::numeric, 2) * (1 + gst_rate), 2), 999999)
                      )
                  ELSE NULL
              END AS keytype_final
          FROM gst_retail_calculations
      ),

      price_list_mappings AS (
          SELECT
              *,
              -- Retail Clearance Price: AU=pl_050_051, NZ=min(pl_497, pl_499)
              CASE
                  WHEN company IN ('11','81','83') THEN pl_050_051
                  WHEN company IN ('50','51','85') THEN
                      NULLIF(LEAST(COALESCE(pl_497, 999999), COALESCE(pl_499, 999999)), 999999)
                  ELSE NULL
              END AS retail_clearance_price,
              -- Manufacturer Support Plan: AU=pl_184 (CO 11), NZ=min(pl_496, pl_498) (CO 50)
              CASE
                  WHEN company = '11' THEN pl_184
                  WHEN company = '50' THEN
                      NULLIF(LEAST(COALESCE(pl_496, 999999), COALESCE(pl_498, 999999)), 999999)
                  ELSE NULL
              END AS manufacturer_support_plan,
              -- Keytype Tool: AU=MAX(pl_191,343,419,446,017), NZ=MAX(pl_044, pl_134) with NULLIF
              CASE
                  WHEN company = '11' THEN
                      NULLIF(GREATEST(COALESCE(pl_191, 0), COALESCE(pl_343, 0), COALESCE(pl_419, 0), COALESCE(pl_446, 0)), 0)
                  WHEN company IN ('81','83') THEN pl_017
                  WHEN company IN ('50','51') THEN
                      NULLIF(GREATEST(COALESCE(pl_044, 0), COALESCE(pl_134, 0)), 0)
                  ELSE NULL
              END AS keytype_tool,
              -- Keytype Plan Method: AU=calculated, NZ=pl_211 for CO 50,51
              CASE
                  WHEN company IN ('11','81','83') THEN NULLIF(keytype_final, 999999)
                  WHEN company IN ('50','51') THEN pl_211
                  ELSE NULL
              END AS keytype_plan_method
          FROM with_retail
      )

      SELECT
          country, "supplierId", sku, company, "startDate", "endDate",
          "priceClass1", "priceClass2", "basePrice", "pricePoint1", "pricePoint2", "pricePoint3",
          "pricePoint4", "pricePoint5", "pricePoint6", "pricePointer", "percentVariance", "percentPriceAdjustment",
          pp6_promo AS "pricePoint6IncludingPromotions",
          pp6_gst AS "pricePoint6IncludingGst",
          pp6_retail AS "pricePoint6RetailNetDiscount",
          -- Retail Price Special: AU=pl_036 (CO 11), NZ=pl_021 (CO 50,51)
          CASE
              WHEN company = '11' THEN pl_036
              WHEN company IN ('50','51') THEN pl_021
              ELSE NULL
          END AS "retailPriceSpecial",
          -- Retail Clearance Price (computed above)
          retail_clearance_price AS "retailClearancePrice",
          -- Price Control Plan: AU=pl_076 (CO 11), NZ=NULL
          CASE WHEN company = '11' THEN pl_076 ELSE NULL END AS "priceControlPlan",
          -- Price Watch Plan: AU=pl_121_au (CO 11), NZ=pl_121_nz (CO 50,51)
          CASE
              WHEN company = '11' THEN pl_121_au
              WHEN company IN ('50','51') THEN pl_121_nz
              ELSE NULL
          END AS "priceWatchPlan",
          -- Manufacturer Support Plan (computed above)
          manufacturer_support_plan AS "manufacturerSupportPlan",
          -- Keytype Tool (computed above)
          keytype_tool AS "keytypeTool",
          -- Keytype Plan Method (computed above)
          keytype_plan_method AS "keyTypePlanMethod",
          -- Delivered Duty Paid: AU pl_390_au (CO 11,81), NZ pl_390_nz (CO 50)
          CASE
              WHEN company IN ('11','81') THEN pl_390_au
              WHEN company = '50' THEN pl_390_nz
              ELSE NULL
          END AS "deliveredDutyPaidMethod",
          -- Exchange Rate Price: CONDITIONAL LOGIC for both AU and NZ
          CASE
              -- AU logic with conditional
              WHEN company IN ('11','61','75','81','83') THEN
                  CASE
                      -- If keytype tool, keytype plan method, and DDP are all NULL
                      WHEN keytype_tool IS NULL AND keytype_plan_method IS NULL AND pl_390_au IS NULL THEN
                          NULLIF(LEAST(
                              COALESCE(pp6_retail, 999999),
                              COALESCE(pl_121_au, 999999),
                              COALESCE(pl_036, 999999),
                              COALESCE(retail_clearance_price, 999999),
                              COALESCE(manufacturer_support_plan, 999999)
                          ), 999999)
                      -- If any of keytype tool, keytype plan method, or DDP exists
                      ELSE
                          NULLIF(LEAST(
                              COALESCE(pl_121_au, 999999),
                              COALESCE(pl_036, 999999),
                              COALESCE(retail_clearance_price, 999999),
                              COALESCE(manufacturer_support_plan, 999999),
                              COALESCE(keytype_tool, 999999),
                              COALESCE(keytype_plan_method, 999999),
                              COALESCE(pl_390_au, 999999)
                          ), 999999)
                  END
              -- NZ logic with conditional
              WHEN company IN ('50','51','85') THEN
                  CASE
                      -- If keytype tool, keytype plan method, and DDP are all NULL
                      WHEN keytype_tool IS NULL AND keytype_plan_method IS NULL AND pl_390_nz IS NULL THEN
                          NULLIF(LEAST(
                              COALESCE(pp6_retail, 999999),
                              COALESCE(pl_121_nz, 999999),
                              COALESCE(pl_021, 999999),
                              COALESCE(retail_clearance_price, 999999),
                              COALESCE(manufacturer_support_plan, 999999)
                          ), 999999)
                      -- If any of keytype tool, keytype plan method, or DDP exists
                      ELSE
                          NULLIF(LEAST(
                              COALESCE(pl_121_nz, 999999),
                              COALESCE(pl_021, 999999),
                              COALESCE(retail_clearance_price, 999999),
                              COALESCE(manufacturer_support_plan, 999999),
                              COALESCE(keytype_tool, 999999),
                              COALESCE(keytype_plan_method, 999999),
                              COALESCE(pl_390_nz, 999999)
                          ), 999999)
                  END
              ELSE NULL
          END AS "exchangeRatePrice"
      FROM price_list_mappings;

      ANALYZE temp_final_data;

      -- Deduplicate final data to prevent ON CONFLICT errors
      DROP TABLE IF EXISTS temp_final_data_dedup;
      CREATE TEMP TABLE temp_final_data_dedup AS
      SELECT DISTINCT ON (company, country, "supplierId", sku)
          *
      FROM temp_final_data
      ORDER BY company, country, "supplierId", sku, "endDate" ASC;
      ANALYZE temp_final_data_dedup;

      SELECT COUNT(*) INTO v_final_data_count FROM temp_final_data_dedup;
      RAISE INFO 'Final data calculated and deduplicated: % rows at %', v_final_data_count, NOW();

      -- 8: TRUE UPSERT with ON CONFLICT DO UPDATE
      INSERT INTO public."tPriceProductRules" (
          country, "supplierId", sku, company, "startDate", "endDate",
          "priceClass1", "priceClass2", "basePrice", "pricePoint1", "pricePoint2", "pricePoint3",
          "pricePoint4", "pricePoint5", "pricePoint6", "pricePointer", "percentVariance", "percentPriceAdjustment",
          "pricePoint6IncludingPromotions", "pricePoint6IncludingGst", "pricePoint6RetailNetDiscount",
          "retailPriceSpecial", "retailClearancePrice", "priceControlPlan", "priceWatchPlan", "manufacturerSupportPlan",
          "keytypeTool", "keyTypePlanMethod", "deliveredDutyPaidMethod", "exchangeRatePrice",
          -- CHANGE: Added isActive column to INSERT
          "isActive", "createdAt", "updatedAt"
      )
      SELECT
          country, "supplierId", sku, company, "startDate", "endDate",
          "priceClass1", "priceClass2", "basePrice", "pricePoint1", "pricePoint2", "pricePoint3",
          "pricePoint4", "pricePoint5", "pricePoint6", "pricePointer", "percentVariance", "percentPriceAdjustment",
          "pricePoint6IncludingPromotions", "pricePoint6IncludingGst", "pricePoint6RetailNetDiscount",
          "retailPriceSpecial", "retailClearancePrice", "priceControlPlan", "priceWatchPlan", "manufacturerSupportPlan",
          "keytypeTool", "keyTypePlanMethod", "deliveredDutyPaidMethod", "exchangeRatePrice",
          -- CHANGE: Mark all new/updated records as active
          TRUE AS "isActive",
          NOW() AS "createdAt",
          NULL AS "updatedAt"
      FROM temp_final_data_dedup
      ON CONFLICT (company,"supplierId",country, sku)
      DO UPDATE SET
          "startDate" = EXCLUDED."startDate",
          "endDate"   = EXCLUDED."endDate",
          "priceClass1" = EXCLUDED."priceClass1",
          "priceClass2" = EXCLUDED."priceClass2",
          "basePrice" = EXCLUDED."basePrice",
          "pricePoint1" = EXCLUDED."pricePoint1",
          "pricePoint2" = EXCLUDED."pricePoint2",
          "pricePoint3" = EXCLUDED."pricePoint3",
          "pricePoint4" = EXCLUDED."pricePoint4",
          "pricePoint5" = EXCLUDED."pricePoint5",
          "pricePoint6" = EXCLUDED."pricePoint6",
          "pricePointer" = EXCLUDED."pricePointer",
          "percentVariance" = EXCLUDED."percentVariance",
          "percentPriceAdjustment" = EXCLUDED."percentPriceAdjustment",
          "pricePoint6IncludingPromotions" = EXCLUDED."pricePoint6IncludingPromotions",
          "pricePoint6IncludingGst" = EXCLUDED."pricePoint6IncludingGst",
          "pricePoint6RetailNetDiscount" = EXCLUDED."pricePoint6RetailNetDiscount",
          "retailPriceSpecial" = EXCLUDED."retailPriceSpecial",
          "retailClearancePrice" = EXCLUDED."retailClearancePrice",
          "priceControlPlan" = EXCLUDED."priceControlPlan",
          "priceWatchPlan" = EXCLUDED."priceWatchPlan",
          "manufacturerSupportPlan" = EXCLUDED."manufacturerSupportPlan",
          "keytypeTool" = EXCLUDED."keytypeTool",
          "keyTypePlanMethod" = EXCLUDED."keyTypePlanMethod",
          "deliveredDutyPaidMethod" = EXCLUDED."deliveredDutyPaidMethod",
          "exchangeRatePrice" = EXCLUDED."exchangeRatePrice",
          -- CHANGE: Reactivate records if they were inactive
          "isActive" = TRUE,
          "updatedAt" = NOW();

      GET DIAGNOSTICS v_total = ROW_COUNT;

      -- Calculate inserted vs updated counts
      SELECT COUNT(*) INTO v_inserted
      FROM public."tPriceProductRules"
      WHERE "updatedAt" IS NULL;

      v_updated := v_total - v_inserted;

      -- Cleanup
      DROP TABLE IF EXISTS temp_infinity_records;
      DROP TABLE IF EXISTS temp_dated_records;
      DROP TABLE IF EXISTS temp_records_to_process;
      DROP TABLE IF EXISTS temp_price_lists;
      DROP TABLE IF EXISTS temp_final_data;
      DROP TABLE IF EXISTS temp_final_data_dedup;


      ELSE
          RAISE INFO 'tPriceProductRules_temp is empty - skipping (no action taken)';
      END IF;

      v_end_time := clock_timestamp() AT TIME ZONE 'Australia/Sydney';

      -- Log end
      INSERT INTO execution_log(job_name, status, start_time, end_time, duration_ms)
      VALUES ('sp_price_product_rules_upsert', 'COMPLETED', v_start_time, v_end_time,
              EXTRACT(MILLISECOND FROM (v_end_time - v_start_time)));

      RAISE INFO 'Price Product Rules Upsert Completed at %', v_end_time;
      -- CHANGE: Updated final log to include inactive count
      RAISE INFO 'Total rows: %, Inserted: %, Updated: %, Marked Inactive: %, Deleted infinity: %',
                 v_total, v_inserted, v_updated, v_marked_inactive, v_deleted_infinity;

  END;

$BODY$;