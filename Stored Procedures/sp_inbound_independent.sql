-- PROCEDURE: public.sp_inbound_independent()

-- DROP PROCEDURE IF EXISTS public.sp_inbound_independent();

CREATE OR REPLACE PROCEDURE public.sp_inbound_independent(
	)
LANGUAGE 'plpgsql'
AS $BODY$
  DECLARE
      v_row_count INTEGER;
      -- CHANGE: Added variables to track inactive record counts
      v_pricelist_inactive INTEGER := 0;
      v_pricelistdetail_inactive INTEGER := 0;
      v_timestamp TIMESTAMP := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
      v_log_id BIGINT;
      v_start_time TIMESTAMPTZ := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
      v_end_time TIMESTAMPTZ;
      v_duration_ms BIGINT;
  BEGIN
      -- Log procedure start
      INSERT INTO execution_log (job_name, status, start_time)
      VALUES ('sp_inbound_independent', 'STARTED', v_start_time)
      RETURNING id INTO v_log_id;

      RAISE NOTICE 'Processing independent tables at %', v_timestamp;

      --------------------------------------------------------------------------------
      -- STEP 1: tCatalogueSales
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tCatalogueSales...';

      IF EXISTS (SELECT 1 FROM public."tCatalogueSales_temp") THEN

          TRUNCATE TABLE public."tCatalogueSales";
          -- Refresh source stats so the INSERT ... SELECT plans correctly
          ANALYZE public."tCatalogueSales_temp";

          WITH deduped AS (
              SELECT
                  t.*,
                  ROW_NUMBER() OVER (
                      PARTITION BY "eventId", sku
                      ORDER BY quantity DESC
                  ) AS rn
              FROM "tCatalogueSales_temp" t
          )
          INSERT INTO public."tCatalogueSales" (
              "eventId", company, sku, page, "salesType",
              quantity, sales, margin, country,
              "createdAt", "updatedAt"
          )
          SELECT
              d."eventId", d.company, d.sku, d.page, d."salesType",
              d.quantity, d.sales, d.margin, d.country,
              (NOW() AT TIME ZONE 'Australia/Sydney'), NULL
          FROM deduped d
          WHERE rn = 1;

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tCatalogueSales: % rows inserted', v_row_count;
	  ANALYZE public."tCatalogueSales";

      ELSE
          RAISE NOTICE 'tCatalogueSales: temp is empty - skipping';
      END IF;

      --------------------------------------------------------------------------------
      -- STEP 2: tCatalogueSalesHeader
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tCatalogueSalesHeader...';

      IF EXISTS (SELECT 1 FROM public."tCatalogueSalesHeader_temp") THEN

          TRUNCATE TABLE public."tCatalogueSalesHeader";
          ANALYZE public."tCatalogueSalesHeader_temp";

          INSERT INTO public."tCatalogueSalesHeader" (
              "eventId", company, "eventDescription", "eventType",
              "startDate", "endDate", "comparisonStartDate", "comparisonEndDate",
              "createdBy", "createdDate", channel, country,
              "createdAt", "updatedAt"
          )
          SELECT DISTINCT ON (t."eventId", t.company, t.country)
              t."eventId",
              'c',
              t."eventDescription",
              t."eventType",
              t."startDate",
              t."endDate",
              t."comparisonStartDate",
              t."comparisonEndDate",
              t."createdBy",
              t."createdDate",
              t.channel,
              t.country,
              (NOW() AT TIME ZONE 'Australia/Sydney'),
              NULL
          FROM public."tCatalogueSalesHeader_temp" t
          ORDER BY t."eventId", t.company, t.country, t."createdDate" DESC;

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tCatalogueSalesHeader: % rows inserted', v_row_count;
    	  ANALYZE public."tCatalogueSalesHeader";

      ELSE
          RAISE NOTICE 'tCatalogueSalesHeader: temp is empty - skipping';
      END IF;

      --------------------------------------------------------------------------------
      -- STEP 3: tInventory
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tInventory...';

      IF EXISTS (SELECT 1 FROM public."tInventory_temp") THEN


          TRUNCATE TABLE public."tInventory";
          ANALYZE public."tInventory_temp";

          INSERT INTO public."tInventory" (
              company, "locationType", sku,
              "weightedAvgCost", "maxUnits", "maxCount",
              "onHand", "onHandOther", "inTransit", "inTransitOther",
              "onOrder", "physicalInventory", "physicalInventoryValue",
              country, "createdAt", "updatedAt"
          )
          SELECT
              t.company, t."locationType", t.sku,
              t."weightedAvgCost", t."maxUnits", t."maxCount",
              t."onHand", t."onHandOther", t."inTransit", t."inTransitOther",
              t."onOrder", t."physicalInventory", t."physicalInventoryValue",
              t.country,
              (NOW() AT TIME ZONE 'Australia/Sydney'), (NOW() AT TIME ZONE 'Australia/Sydney')
          FROM public."tInventory_temp" t;

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tInventory: % rows inserted', v_row_count;
	  ANALYZE public."tInventory";

      ELSE
          RAISE NOTICE 'tInventory: temp is empty - skipping';
      END IF;

      --------------------------------------------------------------------------------
      -- STEP 4: tLocation
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tLocation...';

      IF EXISTS (SELECT 1 FROM public."tLocation_temp") THEN


          TRUNCATE TABLE public."tLocation";
          ANALYZE public."tLocation_temp";

          INSERT INTO public."tLocation" (
              location, "locationName", company, "locationType",
              "associatedLocation", "supplyLocation", "areaName",
              "branchIndicator", "companyName", "companyShortName",
              state, "repcoAreaGroup", zone, "zoneName",
              "stockOnHandLines", "assortmentLines",
              country, "createdAt", "updatedAt"
          )
          SELECT
              t.location, t."locationName", t.company, t."locationType",
              t."associatedLocation", t."supplyLocation", t."areaName",
              t."branchIndicator", t."companyName", t."companyShortName",
              t.state, t."repcoAreaGroup", t.zone, t."zoneName",
              t."stockOnHandLines", t."assortmentLines",
              t.country, (NOW() AT TIME ZONE 'Australia/Sydney'), (NOW() AT TIME ZONE 'Australia/Sydney')
          FROM public."tLocation_temp" t;

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tLocation: % rows inserted', v_row_count;
	  ANALYZE public."tLocation";

      ELSE
          RAISE NOTICE 'tLocation: temp is empty - skipping';
      END IF;

      --------------------------------------------------------------------------------
      -- STEP 5: tPriceList (KEEPING INACTIVE TRACKING LOGIC)
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tPriceList...';

      IF EXISTS (SELECT 1 FROM public."tPriceList_temp") THEN


          DELETE FROM public."tPriceList_temp" t
          USING (
              SELECT
                  "company",
                  "priceList",
                  "country",
                  MIN(ctid) AS keep_ctid
              FROM public."tPriceList_temp"
              GROUP BY "company", "priceList","country"
              HAVING COUNT(*) > 1
          ) dups
          WHERE t."company" = dups."company"
            AND t."priceList" = dups."priceList"
            AND t."country"=dups."country"
            AND t.ctid <> dups.keep_ctid;

          -- CHANGE: Mark records as inactive if they're not in today's data
          UPDATE public."tPriceList"
          SET "isActive" = FALSE,
              "updatedAt" = (NOW() AT TIME ZONE 'Australia/Sydney')
          WHERE "isActive" = TRUE
            AND NOT EXISTS (
                SELECT 1
                FROM public."tPriceList_temp" t
                WHERE t.company = "tPriceList".company
                  AND t."priceList" = "tPriceList"."priceList"
                  AND t.country = "tPriceList".country
            );

          -- CHANGE: Get count of records marked as inactive
          GET DIAGNOSTICS v_pricelist_inactive = ROW_COUNT;
          RAISE NOTICE 'tPriceList: Marked % existing records as inactive', v_pricelist_inactive;

          -- Insert new records or update existing records in main table
          INSERT INTO public."tPriceList" AS main (
              company,
              "priceList",
              "priceListDescription",
              owner,
              active,
              "clearanceType",
              "vehicleInfoRequired",
              "priceListMessageCode",
              "longTermFlag",
              country,
              -- CHANGE: Added isActive column to INSERT
              "isActive",
              "createdAt",
              "updatedAt"
          )
          SELECT
              t.company,
              t."priceList",
              t."priceListDescription",
              t.owner,
              t.active,
              t."clearanceType",
              t."vehicleInfoRequired",
              t."priceListMessageCode",
              t."longTermFlag",
              t.country,
              -- CHANGE: Mark all new/updated records as active
              TRUE AS "isActive",
              (NOW() AT TIME ZONE 'Australia/Sydney') AS "createdAt",
              NULL AS "updatedAt"
          FROM public."tPriceList_temp" t
          ON CONFLICT (company, "priceList", country)
          DO UPDATE
          SET
              "priceListDescription" = EXCLUDED."priceListDescription",
              owner = EXCLUDED.owner,
              active = EXCLUDED.active,
              "clearanceType" = EXCLUDED."clearanceType",
              "vehicleInfoRequired" = EXCLUDED."vehicleInfoRequired",
              "priceListMessageCode" = EXCLUDED."priceListMessageCode",
              "longTermFlag" = EXCLUDED."longTermFlag",
              country = EXCLUDED.country,
              -- CHANGE: Reactivate records if they were inactive
              "isActive" = TRUE,
              "updatedAt" = (NOW() AT TIME ZONE 'Australia/Sydney');

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tPriceList: % rows upserted', v_row_count;

      ELSE
          RAISE NOTICE 'tPriceList: temp is empty - skipping';
      END IF;

      --------------------------------------------------------------------------------
      -- STEP 6: tPriceListDetail
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tPriceListDetail...';

      IF EXISTS (SELECT 1 FROM public."tPriceListDetail_temp") THEN


          UPDATE public."tPriceListDetail"
          SET "isActive" = FALSE,
              "updatedAt" = (NOW() AT TIME ZONE 'Australia/Sydney')
          WHERE "isActive" = TRUE
            AND NOT EXISTS (
                SELECT 1
                FROM public."tPriceListDetail_temp" t
                WHERE t.company = "tPriceListDetail".company
                  AND t.country ="tPriceListDetail".country
                  AND t."priceList" = "tPriceListDetail"."priceList"
                  AND t.sku  = "tPriceListDetail".sku
                  AND t."startDate" <= CURRENT_DATE
                  AND t."endDate"   >= CURRENT_DATE
            );

          GET DIAGNOSTICS v_pricelistdetail_inactive = ROW_COUNT;
          RAISE NOTICE 'tPriceListDetail: Marked % existing records as inactive',
              v_pricelistdetail_inactive;

          WITH dedup AS (
              SELECT *,
                     ROW_NUMBER() OVER (
                         PARTITION BY company, country, "priceList", sku
                         ORDER BY "startDate" DESC
                     ) AS rn
              FROM public."tPriceListDetail_temp"
              WHERE "startDate" <= CURRENT_DATE
                AND "endDate"   >= CURRENT_DATE
          )
          INSERT INTO public."tPriceListDetail" (
              company,
              "priceList",
              sku,
              "dateAdded",
              "startDate",
              "endDate",
              "gstInclusiveIndicator",
              "priceListPrice",
              country,
              "isActive",
              "createdAt",
              "updatedAt"
          )
          SELECT
              t.company,
              t."priceList",
              t.sku,
              t."dateAdded",
              t."startDate",
              t."endDate",
              t."gstInclusiveIndicator",
              t."priceListPrice",
              t.country,
              TRUE AS "isActive",
              (NOW() AT TIME ZONE 'Australia/Sydney') AS "createdAt",
              (NOW() AT TIME ZONE 'Australia/Sydney') AS "updatedAt"
          FROM dedup t
          WHERE rn = 1
          ON CONFLICT (company, country, "priceList", sku)
          DO UPDATE SET
              "dateAdded"              = EXCLUDED."dateAdded",
              "startDate"              = EXCLUDED."startDate",
              "endDate"                = EXCLUDED."endDate",
              "gstInclusiveIndicator"  = EXCLUDED."gstInclusiveIndicator",
              "priceListPrice"         = EXCLUDED."priceListPrice",
              "isActive"               = TRUE,
              "updatedAt"              = (NOW() AT TIME ZONE 'Australia/Sydney');

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tPriceListDetail: % rows upserted', v_row_count;

      ELSE
          RAISE NOTICE 'tPriceListDetail: temp is empty - skipping';
      END IF;

      --------------------------------------------------------------------------------
      -- STEP 7: tPriceProfile (COUNTRY-SPECIFIC)
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tPriceProfile...';

      IF EXISTS (SELECT 1 FROM public."tPriceProfile_temp") THEN


          TRUNCATE TABLE public."tPriceProfile";

          DELETE FROM "tPriceProfile_temp"
          WHERE (country = 'NZ' AND "priceProfile" != 'RET1B')
             OR (country = 'AU' AND "priceProfile" != 'RETLB');

          INSERT INTO "tPriceProfile_temp" (
              company, "priceProfile", "startDate", "endDate",
              "priceClass1", "priceClass2",
              "pricePointer", "percentVariation", "percentPriceAdjust", country
          )
          SELECT '85', 'RET1B', '2020-07-20'::DATE, '9999-12-31'::DATE,
                 'NA' AS "priceClass1",
                 'NA' AS "priceClass2",
                 6, 0, 0, 'NZ'
          WHERE NOT EXISTS (
              SELECT 1 FROM "tPriceProfile_temp"
              WHERE company='85' AND "priceProfile"='RET1B' AND country='NZ'
          );

          -- Refresh source stats (after the temp edits above) so the dedup INSERT plans correctly
          ANALYZE public."tPriceProfile_temp";

          -- Use ROW_NUMBER() to deduplicate
          WITH ranked AS (
              SELECT *,
                     ROW_NUMBER() OVER (
                         PARTITION BY company, "priceProfile",
                                      CASE WHEN country='AU' THEN "startDate" ELSE NULL END,
                                      CASE WHEN country='AU' THEN "endDate" ELSE NULL END,
                                      "priceClass1", "priceClass2", country
                         ORDER BY "startDate" DESC, "endDate" DESC
                     ) AS rn
              FROM "tPriceProfile_temp"
          )
          INSERT INTO "tPriceProfile" (
              company, "priceProfile", "startDate", "endDate",
              "priceClass1", "priceClass2",
              "pricePointer", "percentVariation", "percentPriceAdjust", country
          )
          SELECT company, "priceProfile", "startDate", "endDate",
                 "priceClass1", "priceClass2",
                 "pricePointer", "percentVariation", "percentPriceAdjust", country
          FROM ranked
          WHERE rn = 1;

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tPriceProfile: % rows inserted', v_row_count;
   	  ANALYZE public."tPriceProfile";

      ELSE
          RAISE NOTICE 'tPriceProfile: temp is empty - skipping';
      END IF;

      --------------------------------------------------------------------------------
      -- STEP 8: tSalesY2
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tSalesY2...';

      IF EXISTS (SELECT 1 FROM public."tSalesY2_temp") THEN


          TRUNCATE TABLE public."tSalesY2";
          ANALYZE public."tSalesY2_temp";

          WITH dedup AS (
              SELECT t.ctid,
                     ROW_NUMBER() OVER (
                         PARTITION BY company, "salesType", sku, country
                         ORDER BY sku
                     ) AS rn
              FROM "tSalesY2_temp" t
          )
          DELETE FROM "tSalesY2_temp" t
          USING dedup d
          WHERE t.ctid = d.ctid
            AND d.rn > 1;

          INSERT INTO public."tSalesY2" (
              company, "salesType", sku, "costOfGoods",
              sales, margin,
              "salesQuantity24","salesQuantity23","salesQuantity22","salesQuantity21",
              "salesQuantity20","salesQuantity19","salesQuantity18","salesQuantity17",
              "salesQuantity16","salesQuantity15","salesQuantity14","salesQuantity13",
              "salesGroup1","salesGroup2","salesGroup3","salesGroup4","salesGroup5","salesGroup6",
              "salesNSW","salesVIC","salesQLD","salesSA","salesWA","salesNT","salesTAS",
              country, "createdAt", "updatedAt"
          )
          SELECT
              t.company, t."salesType", t.sku, t."costOfGoods",
              t.sales, t.margin,
              t."salesQuantity24", t."salesQuantity23", t."salesQuantity22", t."salesQuantity21",
              t."salesQuantity20", t."salesQuantity19", t."salesQuantity18", t."salesQuantity17",
              t."salesQuantity16", t."salesQuantity15", t."salesQuantity14", t."salesQuantity13",
              t."salesGroup1", t."salesGroup2", t."salesGroup3", t."salesGroup4",
              t."salesGroup5", t."salesGroup6",
              t."salesNSW", t."salesVIC", t."salesQLD", t."salesSA",
              t."salesWA", t."salesNT", t."salesTAS",
              t.country, (NOW() AT TIME ZONE 'Australia/Sydney'), (NOW() AT TIME ZONE 'Australia/Sydney')
          FROM public."tSalesY2_temp" t;

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tSalesY2: % rows inserted', v_row_count;
	  ANALYZE public."tSalesY2";

      ELSE
          RAISE NOTICE 'tSalesY2: temp is empty - skipping';
      END IF;

      --------------------------------------------------------------------------------
      -- STEP 9: tStockCover
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tStockCover...';

      IF EXISTS (SELECT 1 FROM public."tStockCover_temp") THEN


          TRUNCATE TABLE public."tStockCover";
          ANALYZE public."tStockCover_temp";

          INSERT INTO public."tStockCover" (
              company, sku,
              "stockOnHandGroup1","stockOnHandGroup2","stockOnHandGroup3","stockOnHandGroup4","stockOnHandGroup5",
              "stockCountGroup1","stockCountGroup2","stockCountGroup3","stockCountGroup4","stockCountGroup5",
              "stockCount1Group1","stockCount2Group1","stockCount35Group1","stockCount610Group1","stockCount11Group1",
              "stockCount1Group2","stockCount2Group2","stockCount35Group2","stockCount610Group2","stockCount11Group2",
              "stockCount1Group3","stockCount2Group3","stockCount35Group3","stockCount610Group3","stockCount11Group3",
              "stockCount1Group4","stockCount2Group4","stockCount35Group4","stockCount610Group4","stockCount11Group4",
              "stockCount1Group5","stockCount2Group5","stockCount35Group5","stockCount610Group5","stockCount11Group5",
              country, "createdAt","updatedAt"
          )
          SELECT
              t.company, t.sku,
              t."stockOnHandGroup1",t."stockOnHandGroup2",t."stockOnHandGroup3",t."stockOnHandGroup4",t."stockOnHandGroup5",
              t."stockCountGroup1",t."stockCountGroup2",t."stockCountGroup3",t."stockCountGroup4",t."stockCountGroup5",
              t."stockCount1Group1",t."stockCount2Group1",t."stockCount35Group1",t."stockCount610Group1",t."stockCount11Group1",
              t."stockCount1Group2",t."stockCount2Group2",t."stockCount35Group2",t."stockCount610Group2",t."stockCount11Group2",
              t."stockCount1Group3",t."stockCount2Group3",t."stockCount35Group3",t."stockCount610Group3",t."stockCount11Group3",
              t."stockCount1Group4",t."stockCount2Group4",t."stockCount35Group4",t."stockCount610Group4",t."stockCount11Group4",
              t."stockCount1Group5",t."stockCount2Group5",t."stockCount35Group5",t."stockCount610Group5",t."stockCount11Group5",
              t.country, (NOW() AT TIME ZONE 'Australia/Sydney'), (NOW() AT TIME ZONE 'Australia/Sydney')
          FROM public."tStockCover_temp" t;

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tStockCover: % rows inserted', v_row_count;
	  ANALYZE public."tStockCover";

      ELSE
          RAISE NOTICE 'tStockCover: temp is empty - skipping';
      END IF;

      --------------------------------------------------------------------------------
      -- STEP 10: tCompanyItem
      --------------------------------------------------------------------------------
      RAISE NOTICE 'Processing tCompanyItem...';

      IF EXISTS (SELECT 1 FROM public."tCompanyItem_temp") THEN


          TRUNCATE TABLE public."tCompanyItem";
          ANALYZE public."tCompanyItem_temp";

          INSERT INTO public."tCompanyItem" (
              company, sku, country, "createdAt", "updatedAt"
          )
          SELECT DISTINCT company, sku, country, (NOW() AT TIME ZONE 'Australia/Sydney'), (NOW() AT TIME ZONE 'Australia/Sydney')
          FROM public."tCompanyItem_temp";

          GET DIAGNOSTICS v_row_count = ROW_COUNT;
          RAISE NOTICE 'tCompanyItem: % rows inserted', v_row_count;
	  ANALYZE public."tCompanyItem";

      ELSE
          RAISE NOTICE 'tCompanyItem: temp is empty - skipping';
      END IF;

      -- Calculate duration and log successful completion
      v_end_time := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
      v_duration_ms := EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000;

      UPDATE execution_log
      SET status = 'SUCCESS',
          end_time = v_end_time,
          duration_ms = v_duration_ms
      WHERE id = v_log_id;

      -- CHANGE: Updated final log to include inactive counts
      RAISE NOTICE 'Procedure completed successfully in % ms', v_duration_ms;
      RAISE NOTICE 'tPriceList inactive records: %, tPriceListDetail inactive records: %',
                   v_pricelist_inactive, v_pricelistdetail_inactive;

  EXCEPTION
      WHEN OTHERS THEN
          -- Log failure
          v_end_time := (clock_timestamp() AT TIME ZONE 'Australia/Sydney');
          v_duration_ms := EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000;

          UPDATE execution_log
          SET status = 'FAILED',
              end_time = v_end_time,
              duration_ms = v_duration_ms
          WHERE id = v_log_id;

          RAISE EXCEPTION 'Error in sp_inbound_independent: % - %', SQLERRM, SQLSTATE;
  END;

$BODY$;