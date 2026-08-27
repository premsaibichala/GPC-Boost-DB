-- FUNCTION: public.spMarketingExtract(integer)

-- DROP FUNCTION IF EXISTS public."spMarketingExtract"(integer);

CREATE OR REPLACE FUNCTION public."spMarketingExtract"(
	p_event_id integer)
    RETURNS TABLE("EVENTID" integer, "EVENTDESC" character varying, "COUNTRY" character varying, "CO" character varying, "CHANNEL" character varying, "EVENTTYPE" character varying, "STARTDTE" date, "ENDDTE" date, "PAGE" integer, "PAGEPOSN" integer, "COMOFFERTYPE" character varying, "COMOFFERIC1" character varying, "COMCATMAN" character varying, "OFFERNO" integer, "OFFERNAME" character varying, "PARTNO" character varying, "DESC" character varying, "WEBPARTDESC" character varying, "BRAND" character varying, "IC4" character varying, "SKU" character varying, "SUBSKU" character varying, "FROMPRCIND" text, "COMOFFERHDRCOPY" text, "COMOFFERCOPY" character varying, "IMAGEREF" character varying, "COPYREF" character varying, "TRANSTASMAN" text, "FLNEW" text, "FLHOTPRICE" text, "FLBONUS" text, "FLEXCLUSIVE" text, "FLINTROPRICE" text, "FLLTDSTRSTK" text, "FLNOTAVAILALLSTR" text, "FLNOTAVAILONLINE" text, "FLONLINEONLY" text, "FLORDERYOURSTODAY" text, "FLPRICEDOWN" text, "FLRAINCHECK" text, "FLWAEXCL" text, "FLWARRANTY" text, "FLLIMITQTY" integer, "HYBTGTGRP" text, "FLLOWESTPRICE" text, "FLLMTTIMEONLY" text, "FLWHILESTOCKLAST" text, "FLSTORESTOCKONLY" text, "FLREWARDS" text, "FLCLEARANCE" text, "OFFERLINES" bigint, "OFFERQTY" integer, "FREEQTY" integer, "SAVEPCT" numeric, "TOTADVPRICEGST" numeric, "TOTALEDPRICEGST" numeric, "TOTSAVEPCT" numeric, "TOTSAVEVAL" numeric, "ADVPRICEGST" numeric, "EDPRICEGST" numeric, "CALCSAVEPCT" numeric, "CALCSAVEVAL" numeric, "inventoryReviewIndicator" text, "OTHER" character varying) 
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
      offer_totals AS MATERIALIZED (          -- Added MATERIALIZED
          SELECT
              eod."offerId",
             
              ROUND(SUM(eod."advertisedPriceGst"), 2) AS total_adv_price,
              ROUND(SUM(eod."everydayPriceGst"), 2)  AS total_ed_price
          FROM relevant_details eod
          GROUP BY eod."offerId"
      ),
      offer_lines AS MATERIALIZED (           -- Added MATERIALIZED
          SELECT
              eo."offerId",
              COUNT(DISTINCT eod."sku") AS offerlines
          FROM relevant_offers eo
          JOIN relevant_details eod
              ON eo."offerId" = eod."offerId"
             AND eo."offerNumber" = eod."offerNo"
             AND eo."page" = eod."page"
             AND eo."pagePosition" = eod."pagePosition"
          GROUP BY eo."offerId"
      ),
      base_query AS (
          SELECT
              e."eventId" AS "EVENTID",
              e."eventDescription" AS "EVENTDESC",
              e."country" AS "COUNTRY",
              e."company" AS "CO",
              e."channel" AS "CHANNEL",
              e."eventType" AS "EVENTTYPE",
              e."startDate" AS "STARTDTE",
              e."endDate" AS "ENDDTE",
              eo."page" AS "PAGE",
              CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"
                    ELSE eo."pagePosition"
                END AS "PAGEPOSN",
              CASE
                  WHEN eo."isRewards" = true
                      THEN CONCAT(eo."commercialOfferType", '-Loyal')
                  ELSE eo."commercialOfferType"
              END AS "COMOFFERTYPE",
              eod."comOfferCategory1" AS "COMOFFERIC1",
              eo."commercialCategoryManager" AS "COMCATMAN",
              eo."offerNumber" AS "OFFERNO",
              eo."offerName" AS "OFFERNAME",
              p."partNo" AS "PARTNO",
              p."description" AS "DESC",
              p."webProductDescription" AS "WEBPARTDESC",
              p."brand" AS "BRAND",
              p."itemClass4" AS "IC4",
              p."sku" AS "SKU",
              eod."substituteSku" AS "SUBSKU",
              CASE
                  WHEN eod."fromPriceIndicator" = true THEN 'Y'
                  ELSE NULL
              END AS "FROMPRCIND",
              eo."offerName"::TEXT AS "COMOFFERHDRCOPY",
              eo."offerName" AS "COMOFFERCOPY",
              eo."imageReference" AS "IMAGEREF",
              eo."copyReference" AS "COPYREF",
              NULL::TEXT AS "TRANSTASMAN",
              CASE
                  WHEN eo."isNew" = true THEN 'Y'
                  ELSE NULL
              END AS "FLNEW",
              NULL::TEXT AS "FLHOTPRICE",
              CASE WHEN eo."isBonus" = true THEN 'Y' ELSE NULL END AS "FLBONUS",
              CASE WHEN eo."isExclusive" = true THEN 'Y' ELSE NULL END AS "FLEXCLUSIVE",
              CASE WHEN eo."isIntroPrice" = true THEN 'Y' ELSE NULL END AS "FLINTROPRICE",
              CASE WHEN eo."isLimitedStoreStock" = true THEN 'Y' ELSE NULL END AS "FLLTDSTRSTK",
              CASE WHEN eo."isNotAvailableAllStores" = true THEN 'Y' ELSE NULL END AS "FLNOTAVAILALLSTR",
              CASE WHEN eo."isNotAvailableOnline" = true THEN 'Y' ELSE NULL END AS "FLNOTAVAILONLINE",
              CASE WHEN eo."isOnlineOnly" = true THEN 'Y' ELSE NULL END AS "FLONLINEONLY",
              CASE WHEN eo."isOrderYoursToday" = true THEN 'Y' ELSE NULL END AS "FLORDERYOURSTODAY",
              NULL::TEXT AS "FLPRICEDOWN",
              CASE WHEN eo."isRaincheck" = true THEN 'Y' ELSE NULL END AS "FLRAINCHECK",
              CASE WHEN FALSE = true THEN 'Y' ELSE NULL END AS "FLWAEXCL",
              NULL AS "FLWARRANTY",
              eo."isLimitQuantity" AS "FLLIMITQTY",
              CASE WHEN eo."hybrisTargetGroup" = true THEN 'Y' ELSE NULL END AS "HYBTGTGRP",
              CASE WHEN eo."isLowestPrice" = true THEN 'Y' ELSE NULL END AS "FLLOWESTPRICE",
              CASE WHEN eo."isLimitedTimeOnly" = true THEN 'Y' ELSE NULL END AS "FLLMTTIMEONLY",
              CASE WHEN eo."isWhileStockLast" = true THEN 'Y' ELSE NULL END AS "FLWHILESTOCKLAST",
              CASE WHEN eo."isStoreStockOnly" = true THEN 'Y' ELSE NULL END AS "FLSTORESTOCKONLY",
              CASE WHEN eo."isRewards" = true THEN 'Y' ELSE NULL END AS "FLREWARDS",
              CASE WHEN eo."isClearance" = true THEN 'Y' ELSE NULL END AS "FLCLEARANCE",
              COALESCE(ol.offerlines, 0) AS "OFFERLINES",
              eo."offerQuantity" AS "OFFERQTY",
              eo."freeQuantity" AS "FREEQTY",
              ROUND(eo."savePercent",2) AS "SAVEPCT",
              CASE
                  WHEN eo."OfferTypeId" IN (4,3,5,25,23,15,6,103,115,104,106)
                      THEN COALESCE(ot.total_adv_price, 0)
                  ELSE 0::NUMERIC
              END AS "TOTADVPRICEGST",
              CASE
                  WHEN eo."OfferTypeId" IN (4,3,5,25,23,15,6,103,115,104,106)
                      THEN COALESCE(ot.total_ed_price, 0)
                  ELSE 0::NUMERIC
              END AS "TOTALEDPRICEGST",
              ROUND(eod."advertisedPriceGst", 2) AS "ADVPRICEGST",
              ROUND(eod."everydayPriceGst", 2) AS "EDPRICEGST",
              ROUND(eod."calculatedSavePercentage", 2) AS "CALCSAVEPCT",
              ROUND(eod."calculatedSaveValue", 2) AS "CALCSAVEVAL",
              CASE
                  WHEN eod."inventoryReviewIndicator" = true THEN 'Y'
                  ELSE NULL
              END AS "inventoryReviewIndicator",
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
          LEFT JOIN offer_totals ot
              ON eo."offerId" = ot."offerId"
            
          LEFT JOIN offer_lines ol
              ON eo."offerId" = ol."offerId"
          WHERE e."eventId" = p_event_id
		    AND NOT (
                e."eventType" = 'Retail Catalogue'
                AND eo."pagePosition" = 0
            )
            AND ((e."status" IN ('Open', 'Locked') AND eo."isOfferActive" = TRUE AND eod."isSkuActive" = TRUE) OR (e."status" IN ('Completed', 'Cancelled')))
      )
      SELECT
          bq."EVENTID",
          bq."EVENTDESC",
          bq."COUNTRY",
          bq."CO",
          bq."CHANNEL",
          bq."EVENTTYPE",
          bq."STARTDTE",
          bq."ENDDTE",
          bq."PAGE",
          bq."PAGEPOSN",
          bq."COMOFFERTYPE",
          bq."COMOFFERIC1",
          bq."COMCATMAN",
          bq."OFFERNO",
          bq."OFFERNAME",
          bq."PARTNO",
          bq."DESC",
          bq."WEBPARTDESC",
          bq."BRAND",
          bq."IC4",
          bq."SKU",
          bq."SUBSKU",
          bq."FROMPRCIND",
          bq."COMOFFERHDRCOPY",
          bq."COMOFFERCOPY",
          bq."IMAGEREF",
          bq."COPYREF",
          bq."TRANSTASMAN",
          bq."FLNEW",
          bq."FLHOTPRICE",
          bq."FLBONUS",
          bq."FLEXCLUSIVE",
          bq."FLINTROPRICE",
          bq."FLLTDSTRSTK",
          bq."FLNOTAVAILALLSTR",
          bq."FLNOTAVAILONLINE",
          bq."FLONLINEONLY",
          bq."FLORDERYOURSTODAY",
          bq."FLPRICEDOWN",
          bq."FLRAINCHECK",
          bq."FLWAEXCL",
          bq."FLWARRANTY",
          bq."FLLIMITQTY",
          bq."HYBTGTGRP",
          bq."FLLOWESTPRICE",
          bq."FLLMTTIMEONLY",
          bq."FLWHILESTOCKLAST",
          bq."FLSTORESTOCKONLY",
          bq."FLREWARDS",
          bq."FLCLEARANCE",
          bq."OFFERLINES",
          bq."OFFERQTY",
          bq."FREEQTY",
          bq."SAVEPCT",
          bq."TOTADVPRICEGST",
          bq."TOTALEDPRICEGST",
          ROUND(
              CASE
                  WHEN bq."TOTALEDPRICEGST" > 0
                      THEN (bq."TOTALEDPRICEGST" - bq."TOTADVPRICEGST")
                           / bq."TOTALEDPRICEGST"
                  ELSE 0::NUMERIC
              END,
              2
          ) AS "TOTSAVEPCT",
          ROUND((bq."TOTALEDPRICEGST" - bq."TOTADVPRICEGST"), 2) AS "TOTSAVEVAL",
          bq."ADVPRICEGST",
          bq."EDPRICEGST",
          bq."CALCSAVEPCT",
          bq."CALCSAVEVAL",
          bq."inventoryReviewIndicator",
          bq."OTHER"
      FROM base_query bq
      ORDER BY bq."PAGE", bq."PAGEPOSN", bq."OFFERNO";
  
$BODY$;
