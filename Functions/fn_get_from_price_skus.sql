-- FUNCTION: public.fn_get_from_price_skus(integer)

-- DROP FUNCTION IF EXISTS public.fn_get_from_price_skus(integer);

CREATE OR REPLACE FUNCTION public.fn_get_from_price_skus(
	p_offerid integer)
    RETURNS TABLE(skus text, advprice numeric)
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
      DECLARE
          v_lowestPrice NUMERIC(19,5);
          v_hasCriteriaMet BOOLEAN;
          v_skuList TEXT;
      BEGIN
          -- Check if any products meet the criteria
          SELECT EXISTS (
              WITH "offerSkus" AS (
                  SELECT DISTINCT eod."sku", ev."country", ev."company"
                  FROM "tEventOfferDetail" eod
                  INNER JOIN "tEvent" ev ON eod."eventId" = ev."eventId"
                  WHERE eod."offerId" = p_offerid
              ),
              "pricelistDetail" AS (
                  SELECT
                      pld."sku",
                      pld."priceList",
                      pld."priceListPrice",
                      pld."startDate",
                      pld."country",
                      ROW_NUMBER() OVER (
                          PARTITION BY pld."sku", pld."country",
                          CASE
                              WHEN pld."priceList" = '050' THEN 'clearance'
                              WHEN pld."priceList" = '184' THEN 'special_184'
                              WHEN pld."priceList" = '499' THEN 'nz_clearance_499'
                              WHEN pld."priceList" = '498' THEN 'nz_special_498'
                          END
                          ORDER BY pld."startDate" DESC
                      ) AS group_rn
                  FROM "tPriceListDetail" pld
                  INNER JOIN "tPriceList" pl ON pld."priceList" = pl."priceList"
                  INNER JOIN "offerSkus" os
                      ON os."sku" = pld."sku"
                     AND os."country" = pld."country"
                     AND os."company" = pld.company
                  WHERE pld."priceList" IN ('050','184','499','498')
                    AND pld."isActive"
                    AND pld."startDate" <= CURRENT_DATE
              ),
              "pivoted_prices" AS (
                  SELECT
                      "sku","country",
                      MAX(CASE WHEN "priceList" = '050' AND group_rn = 1 THEN "priceListPrice" END) AS priceList50,
                      MAX(CASE WHEN "priceList" = '184' AND group_rn = 1 THEN "priceListPrice" END) AS priceList184,
                      MAX(CASE WHEN "priceList" = '499' AND group_rn = 1 THEN "priceListPrice" END) AS priceList499,
                      MAX(CASE WHEN "priceList" = '498' AND group_rn = 1 THEN "priceListPrice" END) AS priceList498
                  FROM "pricelistDetail"
                  WHERE group_rn = 1
                  GROUP BY "sku","country"
              ),
              "skuClearance" AS (
                  SELECT
                      os."sku", os."country",
                      CASE
                          WHEN os."country" = 'AU' THEN
                              CASE
                                  WHEN pp.priceList50 IS NOT NULL AND pp.priceList184 IS NOT NULL THEN
                                      CASE WHEN pp.priceList50 <= pp.priceList184 THEN 'Clearance' ELSE 'Mgr Special' END
                                  WHEN pp.priceList50 IS NOT NULL THEN 'Clearance'
                                  WHEN pp.priceList184 IS NOT NULL THEN 'Mgr Special'
                                  ELSE 'N'
                              END
                          WHEN os."country" = 'NZ' THEN
                              CASE
                                  WHEN pp.priceList499 IS NOT NULL AND pp.priceList498 IS NOT NULL THEN
                                      CASE
                                          WHEN pp.priceList499 > pp.priceList498 THEN 'Mgr Special'
                                          WHEN pp.priceList499 <= pp.priceList498 THEN 'Clearance'
                                      END
                                  WHEN pp.priceList499 IS NOT NULL THEN 'Clearance'
                                  WHEN pp.priceList498 IS NOT NULL THEN 'Mgr Special'
                                  ELSE 'N'
                              END
                          ELSE 'N'
                      END AS "clearanceIndicator"
                  FROM "offerSkus" os
                  LEFT JOIN "pivoted_prices" pp ON pp."sku" = os."sku" AND pp."country" = os."country"
              )
              SELECT 1
              FROM "tEventOfferDetail" eod
              INNER JOIN "tEvent" ev ON eod."eventId" = ev."eventId"
              INNER JOIN "tProducts" p ON eod."sku" = p."sku"
              INNER JOIN "tInventory" inv ON inv."sku" = eod."sku"
                                         AND inv."company" IN (ev."company", '12', '52')
              LEFT JOIN "skuClearance" sc ON sc."sku" = eod."sku" AND sc."country" = ev."country"
              WHERE eod."offerId" = p_offerid
			  AND eod."advertisedPriceGst" >= 1
                AND inv."onHand" > 0
                AND (sc."clearanceIndicator" IS NULL OR sc."clearanceIndicator" LIKE 'N')
                AND p."isActive" = TRUE
          ) INTO v_hasCriteriaMet;

          -- Get the lowest price based on criteria
          SELECT COALESCE(
              (WITH "offerSkus" AS (
                  SELECT DISTINCT eod."sku", ev."country", ev."company"
                  FROM "tEventOfferDetail" eod
                  INNER JOIN "tEvent" ev ON eod."eventId" = ev."eventId"
                  WHERE eod."offerId" = p_offerId
              ),
              "pricelistDetail" AS (
                  SELECT
                      pld."sku",
                      pld."priceList",
                      pld."priceListPrice",
                      pld."startDate",
                      pld."country",
                      ROW_NUMBER() OVER (
                          PARTITION BY pld."sku", pld."country",
                          CASE
                              WHEN pld."priceList" = '050' THEN 'clearance'
                              WHEN pld."priceList" = '184' THEN 'special_184'
                              WHEN pld."priceList" = '499' THEN 'nz_clearance_499'
                              WHEN pld."priceList" = '498' THEN 'nz_special_498'
                          END
                          ORDER BY pld."startDate" DESC
                      ) AS group_rn
                  FROM "tPriceListDetail" pld
                  INNER JOIN "tPriceList" pl ON pld."priceList" = pl."priceList"
                  INNER JOIN "offerSkus" os
                      ON os."sku" = pld."sku"
                     AND os."country" = pld."country"
                     AND os."company" = pld.company
                  WHERE pld."priceList" IN ('050','184','499','498')
                    AND pld."isActive"
                    AND pld."startDate" <= CURRENT_DATE
              ),
              "pivoted_prices" AS (
                  SELECT
                      "sku","country",
                      MAX(CASE WHEN "priceList" = '050' AND group_rn = 1 THEN "priceListPrice" END) AS priceList50,
                      MAX(CASE WHEN "priceList" = '184' AND group_rn = 1 THEN "priceListPrice" END) AS priceList184,
                      MAX(CASE WHEN "priceList" = '499' AND group_rn = 1 THEN "priceListPrice" END) AS priceList499,
                      MAX(CASE WHEN "priceList" = '498' AND group_rn = 1 THEN "priceListPrice" END) AS priceList498
                  FROM "pricelistDetail"
                  WHERE group_rn = 1
                  GROUP BY "sku","country"
              ),
              "skuClearance" AS (
                  SELECT
                      os."sku", os."country",
                      CASE
                          WHEN os."country" = 'AU' THEN
                              CASE
                                  WHEN pp.priceList50 IS NOT NULL AND pp.priceList184 IS NOT NULL THEN
                                      CASE WHEN pp.priceList50 <= pp.priceList184 THEN 'Clearance' ELSE 'Mgr Special' END
                                  WHEN pp.priceList50 IS NOT NULL THEN 'Clearance'
                                  WHEN pp.priceList184 IS NOT NULL THEN 'Mgr Special'
                                  ELSE 'N'
                              END
                          WHEN os."country" = 'NZ' THEN
                              CASE
                                  WHEN pp.priceList499 IS NOT NULL AND pp.priceList498 IS NOT NULL THEN
                                      CASE
                                          WHEN pp.priceList499 > pp.priceList498 THEN 'Mgr Special'
                                          WHEN pp.priceList499 <= pp.priceList498 THEN 'Clearance'
                                      END
                                  WHEN pp.priceList499 IS NOT NULL THEN 'Clearance'
                                  WHEN pp.priceList498 IS NOT NULL THEN 'Mgr Special'
                                  ELSE 'N'
                              END
                          ELSE 'N'
                      END AS "clearanceIndicator"
                  FROM "offerSkus" os
                  LEFT JOIN "pivoted_prices" pp ON pp."sku" = os."sku" AND pp."country" = os."country"
              )
               SELECT MIN(eod."advertisedPriceGst")
               FROM "tEventOfferDetail" eod
               INNER JOIN "tEvent" ev ON eod."eventId" = ev."eventId"
               INNER JOIN "tProducts" p ON eod."sku" = p."sku"
               INNER JOIN "tInventory" inv ON inv."sku" = eod."sku"
                                          AND inv."company" IN (ev."company", '12', '52')
               LEFT JOIN "skuClearance" sc ON sc."sku" = eod."sku" AND sc."country" = ev."country"
               WHERE eod."offerId" = p_offerId
			   AND eod."advertisedPriceGst" >= 1
                 AND inv."onHand" > 0
                 AND (sc."clearanceIndicator" IS NULL OR sc."clearanceIndicator" LIKE 'N')
                 AND p."isActive" = TRUE),
              (SELECT MIN(eod."advertisedPriceGst")
               FROM "tEventOfferDetail" eod
               WHERE eod."offerId" = p_offerId
			   AND eod."advertisedPriceGst" >= 1)
          ) INTO v_lowestPrice;

          -- Get comma-separated SKUs based on criteria
          IF v_hasCriteriaMet THEN
              WITH "offerSkus" AS (
                  SELECT DISTINCT eod."sku", ev."country", ev."company"
                  FROM "tEventOfferDetail" eod
                  INNER JOIN "tEvent" ev ON eod."eventId" = ev."eventId"
                  WHERE eod."offerId" = p_offerId
              ),
              "pricelistDetail" AS (
                  SELECT
                      pld."sku",
                      pld."priceList",
                      pld."priceListPrice",
                      pld."startDate",
                      pld."country",
                      ROW_NUMBER() OVER (
                          PARTITION BY pld."sku", pld."country",
                          CASE
                              WHEN pld."priceList" = '050' THEN 'clearance'
                              WHEN pld."priceList" = '184' THEN 'special_184'
                              WHEN pld."priceList" = '499' THEN 'nz_clearance_499'
                              WHEN pld."priceList" = '498' THEN 'nz_special_498'
                          END
                          ORDER BY pld."startDate" DESC
                      ) AS group_rn
                  FROM "tPriceListDetail" pld
                  INNER JOIN "tPriceList" pl ON pld."priceList" = pl."priceList"
                  INNER JOIN "offerSkus" os
                      ON os."sku" = pld."sku"
                     AND os."country" = pld."country"
                     AND os."company" = pld.company
                  WHERE pld."priceList" IN ('050','184','499','498')
                    AND pld."isActive"
                    AND pld."startDate" <= CURRENT_DATE
              ),
              "pivoted_prices" AS (
                  SELECT
                      "sku","country",
                      MAX(CASE WHEN "priceList" = '050' AND group_rn = 1 THEN "priceListPrice" END) AS priceList50,
                      MAX(CASE WHEN "priceList" = '184' AND group_rn = 1 THEN "priceListPrice" END) AS priceList184,
                      MAX(CASE WHEN "priceList" = '499' AND group_rn = 1 THEN "priceListPrice" END) AS priceList499,
                      MAX(CASE WHEN "priceList" = '498' AND group_rn = 1 THEN "priceListPrice" END) AS priceList498
                  FROM "pricelistDetail"
                  WHERE group_rn = 1
                  GROUP BY "sku","country"
              ),
              "skuClearance" AS (
                  SELECT
                      os."sku", os."country",
                      CASE
                          WHEN os."country" = 'AU' THEN
                              CASE
                                  WHEN pp.priceList50 IS NOT NULL AND pp.priceList184 IS NOT NULL THEN
                                      CASE WHEN pp.priceList50 <= pp.priceList184 THEN 'Clearance' ELSE 'Mgr Special' END
                                  WHEN pp.priceList50 IS NOT NULL THEN 'Clearance'
                                  WHEN pp.priceList184 IS NOT NULL THEN 'Mgr Special'
                                  ELSE 'N'
                              END
                          WHEN os."country" = 'NZ' THEN
                              CASE
                                  WHEN pp.priceList499 IS NOT NULL AND pp.priceList498 IS NOT NULL THEN
                                      CASE
                                          WHEN pp.priceList499 > pp.priceList498 THEN 'Mgr Special'
                                          WHEN pp.priceList499 <= pp.priceList498 THEN 'Clearance'
                                      END
                                  WHEN pp.priceList499 IS NOT NULL THEN 'Clearance'
                                  WHEN pp.priceList498 IS NOT NULL THEN 'Mgr Special'
                                  ELSE 'N'
                              END
                          ELSE 'N'
                      END AS "clearanceIndicator"
                  FROM "offerSkus" os
                  LEFT JOIN "pivoted_prices" pp ON pp."sku" = os."sku" AND pp."country" = os."country"
              )
              SELECT STRING_AGG(eod."sku", ',')
              INTO v_skuList
              FROM "tEventOfferDetail" eod
              INNER JOIN "tEvent" ev ON eod."eventId" = ev."eventId"
              INNER JOIN "tProducts" p ON eod."sku" = p."sku"
              INNER JOIN "tInventory" inv ON inv."sku" = eod."sku"
                                         AND inv."company" IN (ev."company", '12', '52')
              LEFT JOIN "skuClearance" sc ON sc."sku" = eod."sku" AND sc."country" = ev."country"
              WHERE eod."offerId" = p_offerId
                AND eod."advertisedPriceGst" = v_lowestPrice
				AND eod."advertisedPriceGst" >= 1
                AND inv."onHand" > 0
                AND (sc."clearanceIndicator" IS NULL OR sc."clearanceIndicator" LIKE 'N')
                AND p."isActive" = TRUE;
          ELSE
              SELECT STRING_AGG(eod."sku", ',')
              INTO v_skuList
              FROM "tEventOfferDetail" eod
              WHERE eod."offerId" = p_offerId
                AND eod."advertisedPriceGst" = v_lowestPrice
				AND eod."advertisedPriceGst" >= 1;
          END IF;

          -- Return single row with two columns
          RETURN QUERY SELECT v_skuList, v_lowestPrice;
      END;
$BODY$;
