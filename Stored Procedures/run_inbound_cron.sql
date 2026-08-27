-- PROCEDURE: public.run_inbound_cron()

-- DROP PROCEDURE IF EXISTS public.run_inbound_cron();

CREATE OR REPLACE PROCEDURE public.run_inbound_cron(
	)
LANGUAGE 'plpgsql'
AS $BODY$
BEGIN
    -- Step 1
    BEGIN
        CALL public.sp_inbound_independent();
        RAISE NOTICE 'Step 1 completed';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Step 1 FAILED: %', SQLERRM;
        RAISE EXCEPTION 'Aborting: Rolling back entire batch';
    END;

    -- Step 2
    BEGIN
        CALL public.sp_tblprod_dpdt();
        RAISE NOTICE 'Step 2 completed';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Step 2 FAILED: %', SQLERRM;
        RAISE EXCEPTION 'Aborting: Rolling back entire batch';
    END;

    -- Step 3
    BEGIN
        CALL public.sp_products_upsert();
        RAISE NOTICE 'Step 3 completed';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Step 3 FAILED: %', SQLERRM;
        RAISE EXCEPTION 'Aborting: Rolling back entire batch';
    END;

    -- Step 4
    BEGIN
        CALL public.sp_price_product_rules_upsert();
        RAISE NOTICE 'Step 4 completed';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Step 4 FAILED: %', SQLERRM;
        RAISE EXCEPTION 'Aborting: Rolling back entire batch';
    END;

    -- Step 5
    BEGIN
        CALL public.sp_process_salesy1();
        RAISE NOTICE 'Step 5 completed';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Step 5 FAILED: %', SQLERRM;
        RAISE EXCEPTION 'Aborting: Rolling back entire batch';
    END;

	-- Step 6: Safeguard — only run the sync if it's after 05:30 Sydney
    -- AND all reference data is present for BOTH countries. This prevents
    -- a missing/half-loaded source table from deactivating everything.
    
    BEGIN
    
    IF (CURRENT_TIMESTAMP AT TIME ZONE 'Australia/Sydney')::time < TIME '05:30:00' THEN
        RAISE NOTICE 'Step 6 skipped: before 05:30 Sydney';

    ELSIF EXISTS (SELECT 1 FROM "tProducts" WHERE "country" = 'AU' AND "isActive")
       AND EXISTS (SELECT 1 FROM "tProducts" WHERE "country" = 'NZ' AND "isActive")
       AND EXISTS (SELECT 1 FROM "tPriceProductRules" WHERE "country" = 'AU' AND "isActive")
       AND EXISTS (SELECT 1 FROM "tPriceProductRules" WHERE "country" = 'NZ' AND "isActive")
       AND EXISTS (SELECT 1 FROM "tPriceListDetail" WHERE "country" = 'AU' AND "isActive")
       AND EXISTS (SELECT 1 FROM "tPriceListDetail" WHERE "country" = 'NZ' AND "isActive")
    THEN
        CALL public.sp_update_offer_and_sku_details();
        RAISE NOTICE 'Step 6 completed';

    ELSE
        RAISE NOTICE 'Step 6 skipped: reference data missing';
    END IF;

    RAISE NOTICE 'All steps completed successfully.';

END;
$BODY$;
