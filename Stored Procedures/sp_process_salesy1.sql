-- PROCEDURE: public.sp_process_salesy1()

-- DROP PROCEDURE IF EXISTS public.sp_process_salesy1();

CREATE OR REPLACE PROCEDURE public.sp_process_salesy1(
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
        VALUES ('sp_process_salesy1', 'STARTED', v_start_time)
        RETURNING id INTO v_log_id;

        RAISE NOTICE 'Processing tSalesY1 at %', v_timestamp;

        BEGIN
            -- Skip the entire process when the source temp table is empty (no action taken)
            IF EXISTS (SELECT 1 FROM public."tSalesY1_temp") THEN


            -- CHANGE: Truncate table instead of upsert
            TRUNCATE TABLE public."tSalesY1";
            -- Refresh source stats (temp + the joined tProducts) so the heavy INSERT ... SELECT plans correctly
            ANALYZE public."tSalesY1_temp";
            ANALYZE public."tProducts";

            --------------------------------------------------------------------
            -- Step 1: Deduplicate temp data
            --------------------------------------------------------------------
            WITH deduped AS (
                SELECT DISTINCT ON (company, "salesType", sku)
                    company,
                    "salesType",
                    sku,
                    "costOfGoods",
                    sales,
                    margin,
                    "salesQuantity12",
                    "salesQuantity11",
                    "salesQuantity10",
                    "salesQuantity9",
                    "salesQuantity8",
                    "salesQuantity7",
                    "salesQuantity6",
                    "salesQuantity5",
                    "salesQuantity4",
                    "salesQuantity3",
                    "salesQuantity2",
                    "salesQuantity1",
                    "salesQuantity0",
                    "salesGroup1",
                    "salesGroup2",
                    "salesGroup3",
                    "salesGroup4",
                    "salesGroup5",
                    "salesGroup6",
                    "salesNSW",
                    "salesVIC",
                    "salesQLD",
                    "salesSA",
                    "salesWA",
                    "salesNT",
                    "salesTAS",
                    "averageSales12Months",
                    "averageSales9Months",
                    "averageSales6Months",
                    "averageSales3Months",
                    "storesSold",
                    country
                FROM public."tSalesY1_temp"
                ORDER BY company, "salesType", sku
            ),

            --------------------------------------------------------------------
            -- Step 2: Join with tProducts to get merchandisingGroup
            --------------------------------------------------------------------
            with_product_info AS (
                SELECT
                    d.*,
                    p."merchandisingGroup"
                FROM deduped d
                LEFT JOIN public."tProducts" p
                    ON d.sku = p.sku AND d.country = p.country
                AND p."isActive"=true
            ),

            --------------------------------------------------------------------
            -- Step 3: Compute calculated fields (Sales Hits & Average)
            --------------------------------------------------------------------
            computed AS (
                SELECT
                    d.*,
                    ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)
                    ) AS "salesHits12Months",
                    ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                     (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)
                    ) AS "salesHits6Months",
                    ROUND(
                        CASE
                            -- Scenario 1: CONSUMER + CASH + 12 hits (exact)
                            WHEN "merchandisingGroup" = 'CONSUMER'
                                 AND "salesType" = 'CASH'
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) = 12
                            THEN GREATEST(
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6" + "salesQuantity7" + "salesQuantity8" + "salesQuantity9" + "salesQuantity10" + "salesQuantity11" +
  "salesQuantity12") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                         ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                         ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 5
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) - 5.0),
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"),
                                         ("salesQuantity4"), ("salesQuantity5"), ("salesQuantity6")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 2
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) - 2.0)
                            )

                            -- Scenario 2: CONSUMER + CASH + ≥10 hits (12m) AND ≥5 hits (6m)
                            WHEN "merchandisingGroup" = 'CONSUMER'
                                 AND "salesType" = 'CASH'
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) >= 10
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) >= 5
                            THEN GREATEST(
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6" + "salesQuantity7" + "salesQuantity8" + "salesQuantity9" + "salesQuantity10" + "salesQuantity11" +
  "salesQuantity12") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                         ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                         ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 4
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) - 4.0),
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"),
                                         ("salesQuantity4"), ("salesQuantity5"), ("salesQuantity6")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 2
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) - 2.0)
                            )

                            -- Scenario 3: CONSUMER + CASH + ≥8 hits (12m) AND ≥4 hits (6m)
                            WHEN "merchandisingGroup" = 'CONSUMER'
                                 AND "salesType" = 'CASH'
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) >= 8
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) >= 4
                            THEN GREATEST(
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6" + "salesQuantity7" + "salesQuantity8" + "salesQuantity9" + "salesQuantity10" + "salesQuantity11" +
  "salesQuantity12") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                         ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                         ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 3
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) - 3.0),
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"),
                                         ("salesQuantity4"), ("salesQuantity5"), ("salesQuantity6")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 1
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) - 1.0)
                            )

                            -- Scenario 4: CONSUMER + CASH + ≥6 hits (12m) AND ≥4 hits (6m)
                            WHEN "merchandisingGroup" = 'CONSUMER'
                                 AND "salesType" = 'CASH'
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) >= 6
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) >= 4
                            THEN GREATEST(
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6" + "salesQuantity7" + "salesQuantity8" + "salesQuantity9" + "salesQuantity10" + "salesQuantity11" +
  "salesQuantity12") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                         ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                         ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 2
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) - 2.0),
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"),
                                         ("salesQuantity4"), ("salesQuantity5"), ("salesQuantity6")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 1
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) - 1.0)
                            )

                            -- Scenario 5: Any product with ≥10 hits (12m) and ≥5 hits (6m)
                            WHEN ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) >= 10
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) >= 5
                            THEN GREATEST(
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6" + "salesQuantity7" + "salesQuantity8" + "salesQuantity9" + "salesQuantity10" + "salesQuantity11" +
  "salesQuantity12") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                         ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                         ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 3
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) - 3.0),
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"),
                                         ("salesQuantity4"), ("salesQuantity5"), ("salesQuantity6")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 2
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) - 2.0)
                            )

                            -- Scenario 6: Any product with ≥8 hits (12m) and ≥4 hits (6m)
                            WHEN ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) >= 8
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) >= 4
                            THEN GREATEST(
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6" + "salesQuantity7" + "salesQuantity8" + "salesQuantity9" + "salesQuantity10" + "salesQuantity11" +
  "salesQuantity12") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                         ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                         ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 2
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) - 2.0),
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"),
                                         ("salesQuantity4"), ("salesQuantity5"), ("salesQuantity6")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 1
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) - 1.0)
                            )

                            -- Scenario 7: Any product with ≥6 hits (12m) and ≥4 hits (6m)
                            WHEN ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) >= 6
                                 AND ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) >= 4
                            THEN GREATEST(
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6" + "salesQuantity7" + "salesQuantity8" + "salesQuantity9" + "salesQuantity10" + "salesQuantity11" +
  "salesQuantity12") -
                                 (SELECT SUM(val) FROM (
                                     SELECT val FROM (VALUES
                                         ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                         ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                         ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                     ) AS t(val)
                                     ORDER BY val DESC
                                     LIMIT 1
                                 ) AS top_vals)
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) - 1.0),
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6") -
                                 (SELECT MAX(val) FROM (VALUES
                                     ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"),
                                     ("salesQuantity4"), ("salesQuantity5"), ("salesQuantity6")
                                 ) AS t(val))
                                ) / (((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                      (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END)) - 1.0)
                            )

                            -- Scenario 8: Medium hits - ≥3 hits (12m)
                            WHEN ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) >= 3
                            THEN GREATEST(
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6" + "salesQuantity7" + "salesQuantity8" + "salesQuantity9" + "salesQuantity10" + "salesQuantity11" +
  "salesQuantity12") -
                                 (SELECT MAX(val) FROM (VALUES
                                     ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                     ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                     ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                 ) AS t(val))
                                ) / 11.0,
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6") -
                                 (SELECT MAX(val) FROM (VALUES
                                     ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                     ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                     ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                 ) AS t(val))
                                ) / 5.0,
                                (("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4") -
                                 (SELECT MAX(val) FROM (VALUES
                                     ("salesQuantity1"), ("salesQuantity2"), ("salesQuantity3"), ("salesQuantity4"),
                                     ("salesQuantity5"), ("salesQuantity6"), ("salesQuantity7"), ("salesQuantity8"),
                                     ("salesQuantity9"), ("salesQuantity10"), ("salesQuantity11"), ("salesQuantity12")
                                 ) AS t(val))
                                ) / 3.0
                            )

                            -- Scenario 9: Low hits - ≥1 hit (12m)
                            WHEN ((CASE WHEN "salesQuantity1" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity2" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity3" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity4" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity5" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity6" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity7" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity8" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity9" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity10" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity11" > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN "salesQuantity12" > 0 THEN 1 ELSE 0 END)) >= 1
                            THEN GREATEST(
                                ("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6" + "salesQuantity7" + "salesQuantity8" + "salesQuantity9" + "salesQuantity10" + "salesQuantity11" +
  "salesQuantity12") / 12.0,
                                ("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4" + "salesQuantity5" +
  "salesQuantity6") / 6.0,
                                ("salesQuantity1" + "salesQuantity2" + "salesQuantity3" + "salesQuantity4") / 4.0
                            )

                            ELSE 0
                        END,
                        2
                    ) AS "averageMonthlySales"
                FROM with_product_info d
            )

            --------------------------------------------------------------------
            -- Step 4: Insert into main table (CHANGED from upsert)
            --------------------------------------------------------------------
            INSERT INTO public."tSalesY1" (
                company, "salesType", sku, "costOfGoods", sales, margin,
                "salesQuantity12", "salesQuantity11", "salesQuantity10", "salesQuantity9",
                "salesQuantity8", "salesQuantity7", "salesQuantity6", "salesQuantity5",
                "salesQuantity4", "salesQuantity3", "salesQuantity2", "salesQuantity1", "salesQuantity0",
                "salesGroup1", "salesGroup2", "salesGroup3", "salesGroup4", "salesGroup5", "salesGroup6",
                "salesNSW", "salesVIC", "salesQLD", "salesSA", "salesWA", "salesNT", "salesTAS",
                "averageSales12Months", "averageSales9Months", "averageSales6Months", "averageSales3Months",
                "storesSold", "salesHits12Months", "salesHits6Months", "averageMonthlySales", country,
                "createdAt", "updatedAt"
            )
            SELECT
                company, "salesType", sku, "costOfGoods", sales, margin,
                "salesQuantity12", "salesQuantity11", "salesQuantity10", "salesQuantity9",
                "salesQuantity8", "salesQuantity7", "salesQuantity6", "salesQuantity5",
                "salesQuantity4", "salesQuantity3", "salesQuantity2", "salesQuantity1", "salesQuantity0",
                "salesGroup1", "salesGroup2", "salesGroup3", "salesGroup4", "salesGroup5", "salesGroup6",
                "salesNSW", "salesVIC", "salesQLD", "salesSA", "salesWA", "salesNT", "salesTAS",
                "averageSales12Months", "averageSales9Months", "averageSales6Months", "averageSales3Months",
                "storesSold", "salesHits12Months", "salesHits6Months", "averageMonthlySales", country,
                (NOW() AT TIME ZONE 'Australia/Sydney') AS "createdAt", NULL AS "updatedAt"
            FROM computed;

            GET DIAGNOSTICS v_row_count = ROW_COUNT;
            RAISE NOTICE 'tSalesY1: % rows inserted', v_row_count;
	    ANALYZE public."tSalesY1";

            ELSE
                RAISE NOTICE 'tSalesY1_temp is empty - skipping (no action taken)';
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

            RAISE WARNING 'Error occurred during tSalesY1 processing: %', SQLERRM;
            RAISE;
        END;

    END;

$BODY$;