-- PROCEDURE: public.sp_products_upsert()

-- DROP PROCEDURE IF EXISTS public.sp_products_upsert();

CREATE OR REPLACE PROCEDURE public.sp_products_upsert(
	)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_insert_count INTEGER := 0;
    -- CHANGE: Added variable to track inactive record count
    v_marked_inactive INTEGER := 0;
    v_start_time   TIMESTAMP;
    v_temp_count   INTEGER := 0;
    v_step_time    TIMESTAMP;
    v_log_id BIGINT;
    v_start_time_log TIMESTAMPTZ := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
    v_end_time TIMESTAMPTZ;
    v_duration_ms BIGINT;
BEGIN
    -- Log procedure start
    INSERT INTO execution_log (job_name, status, start_time)
    VALUES ('sp_products_upsert', 'STARTED', v_start_time_log)
    RETURNING id INTO v_log_id;

    v_start_time := clock_timestamp();
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Starting sp_products_upsert at %', v_start_time;
    RAISE NOTICE '========================================';

    -------------------------------------------------------------------
    -- STEP 1: Validate temp table
    -------------------------------------------------------------------
    v_step_time := clock_timestamp();

    SELECT COUNT(*) INTO v_temp_count
    FROM public."tProducts_temp";

    RAISE NOTICE '[Step 1] Found % rows in tProducts_temp', v_temp_count;

    IF v_temp_count = 0 THEN
        RAISE NOTICE 'No data to process. Exiting.';

        -- Log completion even if no data to process
        v_end_time := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
        v_duration_ms := EXTRACT(EPOCH FROM (v_end_time - v_start_time_log)) * 1000;

        UPDATE execution_log
        SET status = 'SUCCESS',
            end_time = v_end_time,
            duration_ms = v_duration_ms
        WHERE id = v_log_id;

        RETURN;
    END IF;

    -- Capture whether temp holds BOTH AU and NZ before processing

    -------------------------------------------------------------------
    -- STEP 2: Build normalized temp table
    -------------------------------------------------------------------
    DROP TABLE IF EXISTS temp_products_normalized;

    CREATE TEMP TABLE temp_products_normalized ON COMMIT DROP AS
    SELECT
        tp.*,
        COALESCE(tp.country) AS normalized_country
    FROM public."tProducts_temp" tp;

    RAISE NOTICE '[Step 2] Created normalized temp table in % ms',
        EXTRACT(MILLISECOND FROM (clock_timestamp() - v_step_time));

    -------------------------------------------------------------------
    -- STEP 2A: Indexes
    -------------------------------------------------------------------
    v_step_time := clock_timestamp();

    CREATE INDEX idx_temp_prod_sku_country
        ON temp_products_normalized(sku, normalized_country);
    CREATE INDEX idx_temp_prod_itemclass4
        ON temp_products_normalized("itemClass4", normalized_country);
    CREATE INDEX idx_temp_prod_partid
        ON temp_products_normalized("partId", normalized_country);
    CREATE INDEX idx_temp_prod_supplierid
        ON temp_products_normalized("supplierId", normalized_country);

    ANALYZE temp_products_normalized;

    RAISE NOTICE '[Step 2A] Created temp indexes and analyzed in % ms',
        EXTRACT(MILLISECOND FROM (clock_timestamp() - v_step_time));

    -- CHANGE: Mark records as inactive if they're not in today's data
    UPDATE public."tProducts"
    SET "isActive" = FALSE,
        "updatedAt" = (NOW() AT TIME ZONE 'Australia/Sydney')
    WHERE "isActive" = TRUE
      AND NOT EXISTS (
          SELECT 1
          FROM temp_products_normalized t
          WHERE t.sku = "tProducts".sku
            AND t.normalized_country = "tProducts".country
      );

    -- CHANGE: Get count of records marked as inactive
    GET DIAGNOSTICS v_marked_inactive = ROW_COUNT;
    RAISE NOTICE 'Marked % existing records as inactive', v_marked_inactive;

    -------------------------------------------------------------------
    -- STEP 3: Main UPSERT (WITH DISTINCT ON)
    -------------------------------------------------------------------
    v_step_time := clock_timestamp();

    WITH

    -------------------------------------------------------------------
    -- CTE 1: Latest product supplier cost
    -------------------------------------------------------------------
    latest_prod_cost AS NOT MATERIALIZED (
        SELECT
            ranked.sku,
            ranked.country,
            ranked."supplierId",
            ranked."purchaseUOM",
            ranked."conversionFactor",
            ranked."startDate",
            ranked."baseCost",
            ranked."purchaseUomCost" AS "vendorCostbyPurchaseUom",
            ranked."costPerEach"
        FROM (
            SELECT
                ppc.*,
                ROW_NUMBER() OVER (
                    PARTITION BY ppc.sku, ppc.country
                    ORDER BY ppc."startDate" DESC NULLS LAST
                ) AS rn
            FROM public."tProductSupplierCost" ppc
            JOIN (
                SELECT DISTINCT sku, normalized_country
                FROM temp_products_normalized
            ) tp ON ppc.sku = tp.sku
               AND ppc.country = tp.normalized_country
            WHERE ppc."sellTrigger" = 'Y'
        ) ranked
        WHERE ranked.rn = 1
    ),

    -------------------------------------------------------------------
    -- CTE 2: Vendor preference
    -------------------------------------------------------------------
    vendor_pref AS NOT MATERIALIZED (
        SELECT
            ranked.sku,
            ranked.country,
            ranked."supplierId",
            ranked."purchaseUnitOfMeasure",
            ranked."conversionFactor",
            ranked."latestEffectiveCost"
        FROM (
            SELECT
                v.*,
                ROW_NUMBER() OVER (
                    PARTITION BY v.sku, v.country
                    ORDER BY
                        CASE
                            WHEN v."distributionCenter" IN ('820','840','880','865') THEN 1
                            WHEN v."distributionCenter" IN ('839','930','964','965') THEN 2
                            ELSE 3
                        END,
                        v."distributionCenter"
                ) AS rn
            FROM public."tVendorItemDetail" v
            JOIN (
                SELECT DISTINCT sku, normalized_country
                FROM temp_products_normalized
            ) tp ON v.sku = tp.sku
               AND v.country = tp.normalized_country
        ) ranked
        WHERE ranked.rn = 1
    ),

    -------------------------------------------------------------------
    -- CTE 3: Item loadings aggregated
    -------------------------------------------------------------------
    itemloadings_agg AS NOT MATERIALIZED (
        SELECT
            il."itemClass",
            il.country,
            SUM(COALESCE(il."percentageLoading", 0)) AS total_percentage_loading,
            SUM(COALESCE(il."dollarLoading", 0)) AS total_dollar_loading
        FROM public."tItemLoadings_temp" il
        WHERE EXISTS (
            SELECT 1
            FROM temp_products_normalized tp
            WHERE tp."itemClass4" = il."itemClass"
              AND tp.normalized_country = il.country
        )
        GROUP BY il."itemClass", il.country
    ),

    -------------------------------------------------------------------
    -- CTE 4: Deduplicated joined data
    -------------------------------------------------------------------
    joined_data AS (
        SELECT
            tp.sku,
            tp.normalized_country,
            tp.dissection,
            tp.subdissection,
            tp."partNo",
            tp.description,
            tp.brand,
            tp."itemClass4",
            tp."depositSku",
            tp."partId",
            tp."excludeFromB2C",
            tp."pricingActiveB2C",
            tp."b2cPriceStartDate",
            tp."b2cPriceEndDate",
            tp."unitOfMeasure",
            tp.barcode,
            tp."showRoomIndicator",
            tp."coreProductIndicator",
            tp.clearance,
            tp."mspClearanceIndicator",
            tp."toolBoxIndicator",
            tp."dateAdded",
            tp."planningPerCarQuantity",
            tp."maximumPerCarQuantity",
            tp."merchandisingGroup",
            tp."categoryManager",
            tp."categoryAssistant",
            tp."itemClass1",
            tp."itemClass2",
            tp."itemClass3",
            tp."itemClass1Description",
            tp."itemClass2Description",
            tp."itemClass3Description",
            tp."itemClass4Description",
            tp."partStrip",
            tp."supplierId",
            tp.stocked,
            tp."currentEtCatalog",
            tp."webProductDescription",
            tp."thumbnailImage",
            tp."baseImageName",
            tp."purchaseUnitOfMeasure",
            tp."conversionFactor",
            tp."vendorBaseCost",
            tp."vendorForecastStartDate",
            tp."vendorForecastBaseCost",
            tp."vendorForecastPuomCost",
            tp."vendorForecastCostPerEach",
            tp."finalLandedCost",
            tp."interimLandingCost",

            -- Joined columns
            ic."merchandisingGroup" AS ic_merchandisingGroup,
            ic."categoryManager" AS ic_categoryManager,
            ic."categoryAssistant" AS ic_categoryAssistant,
            ic."itemClass1" AS ic_itemClass1,
            ic."itemClass2" AS ic_itemClass2,
            ic."itemClass3" AS ic_itemClass3,
            ic."itemClass1Description" AS ic_itemClass1Description,
            ic."itemClass2Description" AS ic_itemClass2Description,
            ic."itemClass3Description" AS ic_itemClass3Description,
            ic."itemClass4Description" AS ic_itemClass4Description,

            lpc."supplierId" AS lpc_supplierId,
            lpc."purchaseUOM" AS lpc_purchaseUOM,
            lpc."conversionFactor" AS lpc_conversionFactor,
            lpc."startDate" AS lpc_startDate,
            lpc."baseCost" AS lpc_baseCost,
            lpc."vendorCostbyPurchaseUom" AS lpc_vendorCostbyPurchaseUom,
            lpc."costPerEach" AS lpc_costPerEach,

            vp."supplierId" AS vp_supplierId,
            vp."purchaseUnitOfMeasure" AS vp_purchaseUnitOfMeasure,
            vp."conversionFactor" AS vp_conversionFactor,
            vp."latestEffectiveCost" AS vp_latestEffectiveCost,
            vp.sku AS vp_sku,

            sup."supplierName",
            sup."importIndicator",

            ipd."webPartDescription",
            ipd."thumbnailImageName",
            ipd."baseImageName" AS ipd_baseImageName,

            nac."nationalAverageCost",
            nac."trueLandedCost",
            nac."generalProvision",
            nac."importVariant",
            nac."currencyGain",
            nac.rebate,
            nac."internalLoading",

            ila.total_dollar_loading,

            -- Add ctid for ordering in DISTINCT ON
            tp.ctid AS tp_ctid

        FROM temp_products_normalized tp

        LEFT JOIN public."tItemClass" ic
            ON ic."itemClass4" = tp."itemClass4"
           AND ic.country = tp.normalized_country

        LEFT JOIN latest_prod_cost lpc
            ON lpc.sku = tp.sku
           AND lpc.country = tp.normalized_country

        LEFT JOIN vendor_pref vp
            ON vp.sku = tp.sku
           AND vp.country = tp.normalized_country

        LEFT JOIN public."tSupplier_temp" sup
            ON sup."supplierId" = COALESCE(lpc."supplierId", vp."supplierId", tp."supplierId")
           AND sup.country = tp.normalized_country

        LEFT JOIN public."tIicePartDesc_temp" ipd
            ON ipd."partId" = tp."partId"
           AND ipd.country = tp.normalized_country

        LEFT JOIN public."tNationalAverageCost_temp" nac
            ON nac.sku = tp.sku
           AND nac.country = tp.normalized_country

        LEFT JOIN itemloadings_agg ila
            ON ila."itemClass" = tp."itemClass4"
           AND ila.country = tp.normalized_country
    )

    INSERT INTO public."tProducts" (
        sku, country, dissection, subdissection, "partNo", description, brand,
        "itemClass4", "depositSku", "partId",
        "excludeFromB2C", "pricingActiveB2C", "b2cPriceStartDate", "b2cPriceEndDate",
        "unitOfMeasure", barcode, "showRoomIndicator", "coreProductIndicator",
        clearance, "mspClearanceIndicator", "toolBoxIndicator",
        "dateAdded", "planningPerCarQuantity", "maximumPerCarQuantity",
        "merchandisingGroup", "categoryManager", "categoryAssistant",
        "itemClass1", "itemClass2", "itemClass3",
        "itemClass1Description", "itemClass2Description", "itemClass3Description",
        "itemClass4Description",
        "partStrip",
        "supplierId", "supplierName", "importIndicator",
        stocked,
        "currentEtCatalog",
        "webProductDescription", "thumbnailImage", "baseImageName",
        "purchaseUnitOfMeasure", "conversionFactor",
        "vendorCostStartDate", "vendorBaseCost",
        "vendorCostbyPurchaseUom", "vendorCostPerEach",
        "interimLandingCost",
        "vendorForecastStartDate", "vendorForecastBaseCost",
        "vendorForecastPuomCost", "vendorForecastCostPerEach",
        "finalLandedCost",
        "nationalAvgCost", "trueLandedCost", "generalProvision",
        "importVariant", "currencyGain", rebate,
        "nationalAverageCostInternalLoading",
        -- CHANGE: Added isActive column to INSERT
        "isActive", "createdAt", "updatedAt"
    )
    SELECT DISTINCT ON (jd.sku, jd.normalized_country)
        jd.sku,
        jd.normalized_country,
        jd.dissection,
        jd.subdissection,
        jd."partNo",
        jd.description,
        jd.brand,
        jd."itemClass4",
        jd."depositSku",
        jd."partId",
        jd."excludeFromB2C",
        jd."pricingActiveB2C",
        jd."b2cPriceStartDate",
        jd."b2cPriceEndDate",
        jd."unitOfMeasure",
        jd.barcode,
        jd."showRoomIndicator",
        jd."coreProductIndicator",
        jd.clearance,
        jd."mspClearanceIndicator",
        jd."toolBoxIndicator",
        jd."dateAdded",
        jd."planningPerCarQuantity",
        jd."maximumPerCarQuantity",

        COALESCE(jd.ic_merchandisingGroup, jd."merchandisingGroup"),
        COALESCE(jd.ic_categoryManager, jd."categoryManager"),
        COALESCE(jd.ic_categoryAssistant, jd."categoryAssistant"),

        COALESCE(jd.ic_itemClass1, jd."itemClass1"),
        COALESCE(jd.ic_itemClass2, jd."itemClass2"),
        COALESCE(jd.ic_itemClass3, jd."itemClass3"),
        COALESCE(jd.ic_itemClass1Description, jd."itemClass1Description"),
        COALESCE(jd.ic_itemClass2Description, jd."itemClass2Description"),
        COALESCE(jd.ic_itemClass3Description, jd."itemClass3Description"),
        COALESCE(jd.ic_itemClass4Description, jd."itemClass4Description"),

        jd."partStrip",

        COALESCE(jd.lpc_supplierId, jd.vp_supplierId, jd."supplierId"),
        COALESCE(jd."supplierName", ''),
        COALESCE(jd."importIndicator", ''),

        CASE WHEN jd.vp_sku IS NOT NULL THEN TRUE ELSE COALESCE(jd.stocked, FALSE) END,

        jd."currentEtCatalog",

        COALESCE(jd."webPartDescription", jd."webProductDescription"),
        COALESCE(jd."thumbnailImageName", jd."thumbnailImage"),
        COALESCE(jd.ipd_baseImageName, jd."baseImageName"),

        COALESCE(jd.lpc_purchaseUOM, jd.vp_purchaseUnitOfMeasure, jd."purchaseUnitOfMeasure"),
        COALESCE(jd.lpc_conversionFactor, jd.vp_conversionFactor, jd."conversionFactor"),

        jd.lpc_startDate,
        COALESCE(jd.lpc_baseCost, jd.vp_latestEffectiveCost, jd."nationalAverageCost", jd."vendorBaseCost"),
        COALESCE(jd.lpc_vendorCostbyPurchaseUom, jd.vp_latestEffectiveCost, jd."nationalAverageCost"),
        COALESCE(jd.lpc_costPerEach, jd.vp_latestEffectiveCost, jd."nationalAverageCost"),

        COALESCE(jd.total_dollar_loading, jd."interimLandingCost"),

        jd."vendorForecastStartDate",
        jd."vendorForecastBaseCost",
        jd."vendorForecastPuomCost",
        jd."vendorForecastCostPerEach",
        jd."finalLandedCost",

        jd."nationalAverageCost",
        jd."trueLandedCost",
        jd."generalProvision",
        jd."importVariant",
        jd."currencyGain",
        jd.rebate,
        jd."internalLoading",

        -- CHANGE: Mark all new/updated records as active
        TRUE AS "isActive",
        (NOW() AT TIME ZONE 'Australia/Sydney'),
        (NOW() AT TIME ZONE 'Australia/Sydney')

    FROM joined_data jd
    ORDER BY jd.sku, jd.normalized_country, jd.tp_ctid

    ON CONFLICT (sku, country)
    DO UPDATE
    SET
       dissection = EXCLUDED.dissection,
    subdissection = EXCLUDED.subdissection,
    "partNo" = EXCLUDED."partNo",
    description = EXCLUDED.description,
    brand = EXCLUDED.brand,

    "itemClass4" = EXCLUDED."itemClass4",
    "depositSku" = EXCLUDED."depositSku",
    "partId" = EXCLUDED."partId",
    "excludeFromB2C" = EXCLUDED."excludeFromB2C",
    "pricingActiveB2C" = EXCLUDED."pricingActiveB2C",
    "b2cPriceStartDate" = EXCLUDED."b2cPriceStartDate",
    "b2cPriceEndDate" = EXCLUDED."b2cPriceEndDate",

    "unitOfMeasure" = EXCLUDED."unitOfMeasure",
    barcode = EXCLUDED.barcode,

    "showRoomIndicator" = EXCLUDED."showRoomIndicator",
    "coreProductIndicator" = EXCLUDED."coreProductIndicator",
    clearance = EXCLUDED.clearance,
    "mspClearanceIndicator" = EXCLUDED."mspClearanceIndicator",
    "toolBoxIndicator" = EXCLUDED."toolBoxIndicator",

    "dateAdded" = EXCLUDED."dateAdded",
    "planningPerCarQuantity" = EXCLUDED."planningPerCarQuantity",
    "maximumPerCarQuantity" = EXCLUDED."maximumPerCarQuantity",

    "merchandisingGroup" = EXCLUDED."merchandisingGroup",
    "categoryManager" = EXCLUDED."categoryManager",
    "categoryAssistant" = EXCLUDED."categoryAssistant",

    "itemClass1" = EXCLUDED."itemClass1",
    "itemClass2" = EXCLUDED."itemClass2",
    "itemClass3" = EXCLUDED."itemClass3",

    "itemClass1Description" = EXCLUDED."itemClass1Description",
    "itemClass2Description" = EXCLUDED."itemClass2Description",
    "itemClass3Description" = EXCLUDED."itemClass3Description",
    "itemClass4Description" = EXCLUDED."itemClass4Description",

    "partStrip" = EXCLUDED."partStrip",

    "supplierId" = EXCLUDED."supplierId",
    "supplierName" = EXCLUDED."supplierName",
    "importIndicator" = EXCLUDED."importIndicator",

    stocked = EXCLUDED.stocked,
    "currentEtCatalog" = EXCLUDED."currentEtCatalog",

    "webProductDescription" = EXCLUDED."webProductDescription",
    "thumbnailImage" = EXCLUDED."thumbnailImage",
    "baseImageName" = EXCLUDED."baseImageName",

    "purchaseUnitOfMeasure" = EXCLUDED."purchaseUnitOfMeasure",
    "conversionFactor" = EXCLUDED."conversionFactor",

    "vendorCostStartDate" = EXCLUDED."vendorCostStartDate",
    "vendorBaseCost" = EXCLUDED."vendorBaseCost",
    "vendorCostbyPurchaseUom" = EXCLUDED."vendorCostbyPurchaseUom",
    "vendorCostPerEach" = EXCLUDED."vendorCostPerEach",

    "interimLandingCost" = EXCLUDED."interimLandingCost",

    "vendorForecastStartDate" = EXCLUDED."vendorForecastStartDate",
    "vendorForecastBaseCost" = EXCLUDED."vendorForecastBaseCost",
    "vendorForecastPuomCost" = EXCLUDED."vendorForecastPuomCost",
    "vendorForecastCostPerEach" = EXCLUDED."vendorForecastCostPerEach",

    "finalLandedCost" = EXCLUDED."finalLandedCost",

    "nationalAvgCost" = EXCLUDED."nationalAvgCost",
    "trueLandedCost" = EXCLUDED."trueLandedCost",
    "generalProvision" = EXCLUDED."generalProvision",
    "importVariant" = EXCLUDED."importVariant",
    "currencyGain" = EXCLUDED."currencyGain",
    rebate = EXCLUDED.rebate,
    "nationalAverageCostInternalLoading" =
        EXCLUDED."nationalAverageCostInternalLoading",

    -- CHANGE: Reactivate records if they were inactive
    "isActive" = TRUE,
    "updatedAt" = (NOW() AT TIME ZONE 'Australia/Sydney')
    WHERE ROW(
    public."tProducts".sku,
    public."tProducts".country,
    public."tProducts".dissection,
    public."tProducts".subdissection,
    public."tProducts"."partNo",
    public."tProducts".description,
    public."tProducts".brand,
    public."tProducts"."itemClass4",
    public."tProducts"."depositSku",
    public."tProducts"."partId",
    public."tProducts"."excludeFromB2C",
    public."tProducts"."pricingActiveB2C",
    public."tProducts"."b2cPriceStartDate",
    public."tProducts"."b2cPriceEndDate",
    public."tProducts"."unitOfMeasure",
    public."tProducts".barcode,
    public."tProducts"."showRoomIndicator",
    public."tProducts"."coreProductIndicator",
    public."tProducts".clearance,
    public."tProducts"."mspClearanceIndicator",
    public."tProducts"."toolBoxIndicator",
    public."tProducts"."dateAdded",
    public."tProducts"."planningPerCarQuantity",
    public."tProducts"."maximumPerCarQuantity",
    public."tProducts"."merchandisingGroup",
    public."tProducts"."categoryManager",
    public."tProducts"."categoryAssistant",
    public."tProducts"."itemClass1",
    public."tProducts"."itemClass2",
    public."tProducts"."itemClass3",
    public."tProducts"."itemClass1Description",
    public."tProducts"."itemClass2Description",
    public."tProducts"."itemClass3Description",
    public."tProducts"."itemClass4Description",
    public."tProducts"."partStrip",
    public."tProducts"."supplierId",
    public."tProducts"."supplierName",
    public."tProducts"."importIndicator",
    public."tProducts".stocked,
    public."tProducts"."currentEtCatalog",
    public."tProducts"."webProductDescription",
    public."tProducts"."thumbnailImage",
    public."tProducts"."baseImageName",
    public."tProducts"."purchaseUnitOfMeasure",
    public."tProducts"."conversionFactor",
    public."tProducts"."vendorCostStartDate",
    public."tProducts"."vendorBaseCost",
    public."tProducts"."vendorCostbyPurchaseUom",
    public."tProducts"."vendorCostPerEach",
    public."tProducts"."interimLandingCost",
    public."tProducts"."vendorForecastStartDate",
    public."tProducts"."vendorForecastBaseCost",
    public."tProducts"."vendorForecastPuomCost",
    public."tProducts"."vendorForecastCostPerEach",
    public."tProducts"."finalLandedCost",
    public."tProducts"."nationalAvgCost",
    public."tProducts"."trueLandedCost",
    public."tProducts"."generalProvision",
    public."tProducts"."importVariant",
    public."tProducts"."currencyGain",
    public."tProducts".rebate,
    public."tProducts"."nationalAverageCostInternalLoading"

)
IS DISTINCT FROM
ROW(
    EXCLUDED.sku,
    EXCLUDED.country,
    EXCLUDED.dissection,
    EXCLUDED.subdissection,
    EXCLUDED."partNo",
    EXCLUDED.description,
    EXCLUDED.brand,
    EXCLUDED."itemClass4",
    EXCLUDED."depositSku",
    EXCLUDED."partId",
    EXCLUDED."excludeFromB2C",
    EXCLUDED."pricingActiveB2C",
    EXCLUDED."b2cPriceStartDate",
    EXCLUDED."b2cPriceEndDate",
    EXCLUDED."unitOfMeasure",
    EXCLUDED.barcode,
    EXCLUDED."showRoomIndicator",
    EXCLUDED."coreProductIndicator",
    EXCLUDED.clearance,
    EXCLUDED."mspClearanceIndicator",
    EXCLUDED."toolBoxIndicator",
    EXCLUDED."dateAdded",
    EXCLUDED."planningPerCarQuantity",
    EXCLUDED."maximumPerCarQuantity",
    EXCLUDED."merchandisingGroup",
    EXCLUDED."categoryManager",
    EXCLUDED."categoryAssistant",
    EXCLUDED."itemClass1",
    EXCLUDED."itemClass2",
    EXCLUDED."itemClass3",
    EXCLUDED."itemClass1Description",
    EXCLUDED."itemClass2Description",
    EXCLUDED."itemClass3Description",
    EXCLUDED."itemClass4Description",
    EXCLUDED."partStrip",
    EXCLUDED."supplierId",
    EXCLUDED."supplierName",
    EXCLUDED."importIndicator",
    EXCLUDED.stocked,
    EXCLUDED."currentEtCatalog",
    EXCLUDED."webProductDescription",
    EXCLUDED."thumbnailImage",
    EXCLUDED."baseImageName",
    EXCLUDED."purchaseUnitOfMeasure",
    EXCLUDED."conversionFactor",
    EXCLUDED."vendorCostStartDate",
    EXCLUDED."vendorBaseCost",
    EXCLUDED."vendorCostbyPurchaseUom",
    EXCLUDED."vendorCostPerEach",
    EXCLUDED."interimLandingCost",
    EXCLUDED."vendorForecastStartDate",
    EXCLUDED."vendorForecastBaseCost",
    EXCLUDED."vendorForecastPuomCost",
    EXCLUDED."vendorForecastCostPerEach",
    EXCLUDED."finalLandedCost",
    EXCLUDED."nationalAvgCost",
    EXCLUDED."trueLandedCost",
    EXCLUDED."generalProvision",
    EXCLUDED."importVariant",
    EXCLUDED."currencyGain",
    EXCLUDED.rebate,
    EXCLUDED."nationalAverageCostInternalLoading"

);

    GET DIAGNOSTICS v_insert_count = ROW_COUNT;

    RAISE NOTICE '[Step 3] Main upsert completed in % ms',
        EXTRACT(MILLISECOND FROM (clock_timestamp() - v_step_time));

    -------------------------------------------------------------------
    -- STEP 4: Cleanup
    -------------------------------------------------------------------
    DROP TABLE IF EXISTS temp_products_normalized;


    RAISE NOTICE '========================================';
    RAISE NOTICE 'sp_products_upsert completed successfully';
    RAISE NOTICE 'Total rows affected: %', v_insert_count;
    -- CHANGE: Added inactive count to final log message
    RAISE NOTICE 'Records marked inactive: %', v_marked_inactive;
    RAISE NOTICE 'Total execution time: % ms',
        EXTRACT(MILLISECOND FROM (clock_timestamp() - v_start_time));
    RAISE NOTICE '========================================';

    -- Calculate duration and log successful completion
    v_end_time := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
    v_duration_ms := EXTRACT(EPOCH FROM (v_end_time - v_start_time_log)) * 1000;

    UPDATE execution_log
    SET status = 'SUCCESS',
        end_time = v_end_time,
        duration_ms = v_duration_ms
    WHERE id = v_log_id;

    RAISE NOTICE 'Procedure logged successfully with duration % ms', v_duration_ms;

EXCEPTION
    WHEN OTHERS THEN
        -- Log failure
        v_end_time := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
        v_duration_ms := EXTRACT(EPOCH FROM (v_end_time - v_start_time_log)) * 1000;

        UPDATE execution_log
        SET status = 'FAILED',
            end_time = v_end_time,
            duration_ms = v_duration_ms
        WHERE id = v_log_id;

        RAISE EXCEPTION 'Error in sp_products_upsert: % - %', SQLERRM, SQLSTATE;
END;
$BODY$;