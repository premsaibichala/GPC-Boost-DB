-- FUNCTION: public.spMarketingExtract(integer)

-- DROP FUNCTION IF EXISTS public."spMarketingExtract"(integer);

CREATE OR REPLACE FUNCTION public."spMarketingExtract"(
	p_event_id integer)
    RETURNS TABLE("PAGE" integer, "POSITION" integer, "ITEMCLASS" character varying, "OFFERTYPE" character varying, "REWARDS" text, "PARTNO" character varying, "SKU" character varying, "BRAND" character varying, "OFFERNAME" character varying, "OFFERCOPY" character varying, "IMAGEREF" character varying, "ADVPRICE" numeric, "EDPRICE" numeric, "SAVEVAL" numeric, "SAVEPCT" numeric, "FROMPRICE" numeric, "FROMPRICEPARTNO" character varying, "CALLOUTS" text, "DISCLAIMERS" text, "OTHER" character varying)
    LANGUAGE 'sql'
    COST 100
    STABLE PARALLEL SAFE
    ROWS 1000

AS $BODY$
      WITH relevant_offers AS MATERIALIZED (  -- Added MATERIALIZED
          SELECT *
          FROM public."tEventOffer" eo
          WHERE eo."eventId" = p_event_id
      ),
      relevant_details AS MATERIALIZED (      -- Added MATERIALIZED
          SELECT *
          FROM public."tEventOfferDetail" eod
          WHERE eod."eventId" = p_event_id
      ),
      from_price AS MATERIALIZED (
          SELECT DISTINCT ON (eod."offerId")
              eod."offerId",
              ROUND(eod."advertisedPriceGst", 0) AS from_price,
              p."partNo" AS from_price_part_no
          FROM relevant_details eod
          INNER JOIN public."tProducts" p
              ON eod."sku" = p."sku"
          WHERE eod."fromPriceIndicator" = true
          ORDER BY eod."offerId", eod."advertisedPriceGst" ASC
      ),
      offer_brand AS MATERIALIZED (
          SELECT
              eod."offerId",
              CASE
                  WHEN COUNT(DISTINCT p."brand") > 1 THEN 'Multiple'
                  ELSE MIN(p."brand")
              END AS brand
          FROM relevant_details eod
          INNER JOIN public."tProducts" p
              ON eod."sku" = p."sku"
          GROUP BY eod."offerId"
      ),
      base_query AS (
          SELECT
              eo."page" AS "PAGE",
              CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"
                    ELSE eo."pagePosition"
                END AS "POSITION",
              eo."offerNumber" AS "OFFERNO_SORT",
              eod."comOfferCategory1" AS "ITEMCLASS",
              CASE
                  WHEN eo."isRewards" = true
                      THEN CONCAT(eo."commercialOfferType", '-Loyal')
                  ELSE eo."commercialOfferType"
              END AS "OFFERTYPE",
              CASE WHEN eo."isRewards" = true THEN 'Yes' ELSE NULL END AS "REWARDS",
              p."partNo" AS "PARTNO",
              p."sku" AS "SKU",
              ob.brand AS "BRAND",
              eo."offerName" AS "OFFERNAME",
              eo."offerName" AS "OFFERCOPY",
              eo."imageReference" AS "IMAGEREF",
              ROUND(eod."advertisedPriceGst", 2) AS "ADVPRICE",
              ROUND(eod."everydayPriceGst", 2) AS "EDPRICE",
              ROUND((eod."everydayPriceGst" - eod."advertisedPriceGst"), 2) AS "SAVEVAL",
              ROUND(
                  CASE
                      WHEN eod."everydayPriceGst" > 0
                          THEN (eod."everydayPriceGst" - eod."advertisedPriceGst")
                               / eod."everydayPriceGst"
                      ELSE 0::NUMERIC
                  END,
                  4
              ) AS "SAVEPCT",
              fp.from_price AS "FROMPRICE",
              fp.from_price_part_no AS "FROMPRICEPARTNO",
              NULLIF(
                  CONCAT_WS(', ',
                      CASE WHEN eo."isClearance" = true THEN 'Clearance' END,
                      CASE WHEN eo."isExclusive" = true THEN 'Exclusive' END,
                      CASE WHEN eo."isNew" = true THEN 'New' END,
                      CASE WHEN eo."isLowestPrice" = true THEN 'Lowest Price' END,
                      CASE WHEN eod."fromPriceIndicator" = true THEN 'From Price' END,
                      CASE WHEN eo."isIntroPrice" = true THEN 'Intro Price' END,
                      CASE WHEN eo."isBonus" = true THEN 'Bonus' END
                  ),
                  ''
              ) AS "CALLOUTS",
              NULLIF(
                  CONCAT_WS(', ',
                      CASE WHEN eo."isLimitQuantity" > 0 THEN 'Limited Quantity' END,
                      CASE WHEN eo."isOnlineOnly" = true THEN 'Online Only' END,
                      CASE WHEN eo."isNotAvailableOnline" = true THEN 'Not Avail Online' END,
                      CASE WHEN eo."isRaincheck" = true THEN 'No Rain Check' END,
                      CASE WHEN eo."isOrderYoursToday" = true THEN 'Order Yours Today' END,
                      CASE WHEN eo."isNotAvailableAllStores" = true THEN 'Not Available All Stores' END,
                      CASE WHEN eo."isLimitedStoreStock" = true THEN 'Limited Store Stock' END,
                      CASE WHEN eo."isWhileStockLast" = true THEN 'While Stock(s) Last' END,
                      CASE WHEN eo."isStoreStockOnly" = true THEN 'Store Stock Only' END
                  ),
                  ''
              ) AS "DISCLAIMERS",
              eo."otherDetails" AS "OTHER"
          FROM public."tEvent" e
          INNER JOIN relevant_offers eo
              ON e."eventId" = eo."eventId"
          INNER JOIN relevant_details eod
              ON eo."eventId" = eod."eventId"
             AND eo."page" = eod."page"
             AND eo."pagePosition" = eod."pagePosition"
             AND eo."offerNumber" = eod."offerNo"
             AND eo."offerId" = eod."offerId"
          INNER JOIN public."tProducts" p
              ON eod."sku" = p."sku"
          LEFT JOIN from_price fp
              ON eo."offerId" = fp."offerId"
          LEFT JOIN offer_brand ob
              ON eo."offerId" = ob."offerId"
          WHERE e."eventId" = p_event_id
		    AND NOT (
                e."eventType" = 'Retail Catalogue'
                AND eo."pagePosition" = 0
            )
            AND ((e."status" IN ('Open', 'Locked') AND eo."isOfferActive" = TRUE AND eod."isSkuActive" = TRUE) OR (e."status" IN ('Completed', 'Cancelled')))
      )
      SELECT
          bq."PAGE",
          bq."POSITION",
          bq."ITEMCLASS",
          bq."OFFERTYPE",
          bq."REWARDS",
          bq."PARTNO",
          bq."SKU",
          bq."BRAND",
          bq."OFFERNAME",
          bq."OFFERCOPY",
          bq."IMAGEREF",
          bq."ADVPRICE",
          bq."EDPRICE",
          bq."SAVEVAL",
          bq."SAVEPCT",
          bq."FROMPRICE",
          bq."FROMPRICEPARTNO",
          bq."CALLOUTS",
          bq."DISCLAIMERS",
          bq."OTHER"
      FROM base_query bq
      ORDER BY bq."PAGE", bq."POSITION", bq."OFFERNO_SORT";

$BODY$;
