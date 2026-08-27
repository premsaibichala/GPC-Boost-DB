-- PROCEDURE: public.sp_tblprod_dpdt()

-- DROP PROCEDURE IF EXISTS public.sp_tblprod_dpdt();

CREATE OR REPLACE PROCEDURE public.sp_tblprod_dpdt(
	)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_row_count INTEGER;
    v_timestamp TIMESTAMP := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
    v_log_id BIGINT;
    v_start_time TIMESTAMPTZ := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
    v_end_time TIMESTAMPTZ;
    v_duration_ms BIGINT;
BEGIN
    -- Log procedure start
    INSERT INTO execution_log (job_name, status, start_time)
    VALUES ('sp_tblprod_dpdt', 'STARTED', v_start_time)
    RETURNING id INTO v_log_id;

    RAISE NOTICE 'Processing independent tables at %', v_timestamp;

    BEGIN
        --------------------------------------------------------------------
        -- 1. DEDUP for tIicePartDesc_temp and Truncate/Insert tIicePartDesc
        --------------------------------------------------------------------
        IF EXISTS (SELECT 1 FROM public."tIicePartDesc_temp") THEN


        DELETE FROM public."tIicePartDesc_temp" t
        USING (
            SELECT "partId", MIN(ctid) AS keep_ctid
            FROM public."tIicePartDesc_temp"
            GROUP BY "partId"
            HAVING COUNT(*) > 1
        ) dups
        WHERE t."partId" = dups."partId"
          AND t.ctid <> dups.keep_ctid;

        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        RAISE NOTICE 'tIicePartDesc_temp dedup removed % rows', v_row_count;

        -- CHANGE: Truncate table instead of upsert
        TRUNCATE TABLE public."tIicePartDesc";
        ANALYZE public."tIicePartDesc_temp";

        INSERT INTO public."tIicePartDesc" (
            "partId", country, sku,
            "webPartDescription",
            "thumbnailImageName",
            "baseImageName",
            "marketingCopy",
            "createdAt", "updatedAt"
        )
        SELECT
            t."partId", t.country, t.sku,
            t."webPartDescription",
            t."thumbnailImageName",
            t."baseImageName",
            t."marketingCopy",
            (NOW() AT TIME ZONE 'Australia/Sydney'), NULL
        FROM public."tIicePartDesc_temp" t;

        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        RAISE NOTICE 'tIicePartDesc: % rows inserted', v_row_count;
	ANALYZE public."tIicePartDesc";

        ELSE
            RAISE NOTICE 'tIicePartDesc_temp is empty - skipping';
        END IF;

        --------------------------------------------------------------------
        -- 2. Truncate/Insert NationalAverageCost
        --------------------------------------------------------------------
        IF EXISTS (SELECT 1 FROM public."tNationalAverageCost_temp") THEN


        -- CHANGE: Truncate table instead of upsert
        TRUNCATE TABLE public."tNationalAverageCost";
        ANALYZE public."tNationalAverageCost_temp";

        INSERT INTO public."tNationalAverageCost" (
            country, sku, company,
            "effectiveFromDate", "effectiveToDate",
            "nationalAverageCost", "trueLandedCost",
            "generalProvision", "importVariant",
            "currencyGain", rebate, "internalLoading",
            "createdAt", "updatedAt"
        )
        SELECT
            t.country, t.sku, t.company,
            t."effectiveFromDate", t."effectiveToDate",
            t."nationalAverageCost", t."trueLandedCost",
            t."generalProvision", t."importVariant",
            t."currencyGain", t.rebate, t."internalLoading",
            (NOW() AT TIME ZONE 'Australia/Sydney'), (NOW() AT TIME ZONE 'Australia/Sydney')
        FROM public."tNationalAverageCost_temp" t;

        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        RAISE NOTICE 'NationalAverageCost: % rows inserted', v_row_count;
	ANALYZE public."tNationalAverageCost";

        ELSE
            RAISE NOTICE 'tNationalAverageCost_temp is empty - skipping';
        END IF;

        --------------------------------------------------------------------
        -- 3. Truncate/Insert Supplier
        --------------------------------------------------------------------
        IF EXISTS (SELECT 1 FROM public."tSupplier_temp") THEN


        -- CHANGE: Truncate table instead of upsert
        TRUNCATE TABLE public."tSupplier";
        ANALYZE public."tSupplier_temp";

        INSERT INTO public."tSupplier" (
            "supplierId", country, "supplierName",
            "importIndicator", "createdDate", "termsCode",
            "d365SupplierId", "d365SupplierType",
            "createdAt", "updatedAt"
        )
        SELECT
            t."supplierId", t.country, t."supplierName",
            t."importIndicator", t."createdDate", t."termsCode",
            t."d365SupplierId", t."d365SupplierType",
            (NOW() AT TIME ZONE 'Australia/Sydney'), (NOW() AT TIME ZONE 'Australia/Sydney')
        FROM public."tSupplier_temp" t
        WHERE COALESCE(TRIM(LOWER(t."supplierId")), '') NOT IN ('unknown', '*unknown*', '');

        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        RAISE NOTICE 'Supplier: % rows inserted', v_row_count;
	ANALYZE public."tSupplier";

        ELSE
            RAISE NOTICE 'tSupplier_temp is empty - skipping';
        END IF;

        --------------------------------------------------------------------
        -- 4. Truncate/Insert VendorItemDetail
        --------------------------------------------------------------------
        IF EXISTS (SELECT 1 FROM public."tVendorItemDetail_temp") THEN


        -- CHANGE: Truncate table instead of upsert
        TRUNCATE TABLE public."tVendorItemDetail";
        ANALYZE public."tVendorItemDetail_temp";

        INSERT INTO public."tVendorItemDetail" (
            "distributionCenter", "supplierId", sku,
            "latestEffectiveCost", "baseUnitOfMeasure",
            "purchaseUnitOfMeasure", "conversionFactor",
            "deliveryNoteRequired", "leadTime",
            "minimumOrderQuantity", "orderMultiple",
            "d365SupplierId", "d365SupplierType",
            country, "createdAt", "updatedAt"
        )
        SELECT
            t."distributionCenter", t."supplierId", t.sku,
            t."latestEffectiveCost", t."baseUnitOfMeasure",
            t."purchaseUnitOfMeasure", t."conversionFactor",
            t."deliveryNoteRequired", t."leadTime",
            t."minimumOrderQuantity", t."orderMultiple",
            t."d365SupplierId", t."d365SupplierType",
            t.country, (NOW() AT TIME ZONE 'Australia/Sydney'), (NOW() AT TIME ZONE 'Australia/Sydney')
        FROM public."tVendorItemDetail_temp" t;

        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        RAISE NOTICE 'VendorItemDetail: % rows inserted', v_row_count;
	ANALYZE  public."tVendorItemDetail";

        ELSE
            RAISE NOTICE 'tVendorItemDetail_temp is empty - skipping';
        END IF;

        --------------------------------------------------------------------
        -- 5. Truncate/Insert ItemClass
        --------------------------------------------------------------------
        IF EXISTS (SELECT 1 FROM public."tItemClass_temp") THEN


        -- CHANGE: Truncate table instead of upsert
        TRUNCATE TABLE public."tItemClass";
        ANALYZE public."tItemClass_temp";

        INSERT INTO public."tItemClass" (
            "itemClass1","itemClass2","itemClass3","itemClass4",
            country,"merchandisingGroup","categoryManager",
            "categoryAssistant","itemClass1Description",
            "itemClass2Description","itemClass3Description",
            "itemClass4Description","createdAt","updatedAt"
        )
        SELECT
            t."itemClass1",t."itemClass2",t."itemClass3",t."itemClass4",
            t.country,t."merchandisingGroup",t."categoryManager",
            t."categoryAssistant",t."itemClass1Description",
            t."itemClass2Description",t."itemClass3Description",
            t."itemClass4Description",(NOW() AT TIME ZONE 'Australia/Sydney'),(NOW() AT TIME ZONE 'Australia/Sydney')
        FROM public."tItemClass_temp" t;

        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        RAISE NOTICE 'ItemClass: % rows inserted', v_row_count;
	ANALYZE public."tItemClass";

        ELSE
            RAISE NOTICE 'tItemClass_temp is empty - skipping';
        END IF;

        --------------------------------------------------------------------
        -- 6. Truncate/Insert ItemLoadings
        --------------------------------------------------------------------
        IF EXISTS (SELECT 1 FROM public."tItemLoadings_temp") THEN


        -- CHANGE: Truncate table instead of upsert
        TRUNCATE TABLE public."tItemLoadings";
        ANALYZE public."tItemLoadings_temp";

        INSERT INTO public."tItemLoadings" (
            "supplierId", sku, "itemClass", country,
            "parameterType","loadingLevel","dateAdded","startDate",
            "percentageLoading","dollarLoading","createdAt","updatedAt"
        )
        SELECT
            t."supplierId",t.sku,t."itemClass",t.country,
            t."parameterType",t."loadingLevel",t."dateAdded",
            t."startDate",t."percentageLoading",t."dollarLoading",
            (NOW() AT TIME ZONE 'Australia/Sydney'),NULL
        FROM public."tItemLoadings_temp" t;

        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        RAISE NOTICE 'ItemLoadings: % rows inserted', v_row_count;
	ANALYZE public."tItemLoadings";

        ELSE
            RAISE NOTICE 'tItemLoadings_temp is empty - skipping';
        END IF;

        --------------------------------------------------------------------
        -- 7. Truncate/Insert ProductSupplierCost
        --------------------------------------------------------------------
        IF EXISTS (SELECT 1 FROM public."tProductSupplierCost_temp") THEN


        -- CHANGE: Truncate table instead of upsert
        TRUNCATE TABLE public."tProductSupplierCost";
        ANALYZE public."tProductSupplierCost_temp";

        INSERT INTO public."tProductSupplierCost" (
            country,
            "supplierId",
            sku,
            "costLocation",
            "purchaseUOM",
            "startDate",
            "endDate",
            "rapSellFromDate",
            "sellTrigger",
            "packageType",
            "conversionFactor",
            "fromQuantity",
            "toQuantity",
            "baseCost",
            "discountAmount",
            "purchaseUomCost",
            "costPerEach",
            "createdAt",
            "updatedAt"
        )
        SELECT DISTINCT ON ("supplierId", sku)
            country,
            "supplierId",
            sku,
            "costLocation",
            "purchaseUOM",
            "startDate",
            "endDate",
            "rapSellFromDate",
            "sellTrigger",
            "packageType",
            "conversionFactor",
            "fromQuantity",
            "toQuantity",
            "baseCost",
            "discountAmount",
            "purchaseUomCost",
            "costPerEach",
            (NOW() AT TIME ZONE 'Australia/Sydney') AS "createdAt",
            NULL AS "updatedAt"
        FROM "tProductSupplierCost_temp"
        ORDER BY
            "supplierId",
            sku,
            CASE WHEN "sellTrigger" = 'Y' THEN 0 ELSE 1 END,
            "startDate" DESC,
            "endDate" DESC;

        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        RAISE NOTICE 'ProductSupplierCost: % rows inserted', v_row_count;
	ANALYZE public."tProductSupplierCost";

        ELSE
            RAISE NOTICE 'tProductSupplierCost_temp is empty - skipping';
        END IF;

        -- Calculate duration and log successful completion
        v_end_time := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
        v_duration_ms := EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000;

        UPDATE execution_log
        SET status = 'SUCCESS',
            end_time = v_end_time,
            duration_ms = v_duration_ms
        WHERE id = v_log_id;

        RAISE NOTICE 'Procedure completed successfully in % ms', v_duration_ms;

    EXCEPTION WHEN OTHERS THEN
        -- Log failure
        v_end_time := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
        v_duration_ms := EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000;

        UPDATE execution_log
        SET status = 'FAILED',
            end_time = v_end_time,
            duration_ms = v_duration_ms
        WHERE id = v_log_id;

        RAISE WARNING 'Error occurred: %', SQLERRM;
        RAISE;
    END;

END;
$BODY$;