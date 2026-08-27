-- FUNCTION: public.spRetailTieupDetail(integer)

-- DROP FUNCTION IF EXISTS public."spRetailTieupDetail"(integer);

CREATE OR REPLACE FUNCTION public."spRetailTieupDetail"(
	p_event_id integer)
    RETURNS TABLE("eventDescription" character varying, page integer, "pagePosition" integer, "comOfferCategory1" character varying, "offerNo" integer, "commercialOfferType" character varying, "offerId" integer, sku character varying, brand character varying, "partNo" character varying, description character varying, "tieUp" text, "everydayPriceGst" numeric, "advertisedPriceGst" numeric, "allocationGroup" character varying, "allocationType" character varying, "group0Quantity" integer, "group1Quantity" integer, "group2Quantity" integer, "group3Quantity" integer, "group4Quantity" integer, "group5Quantity" integer, "totalTieUp" numeric, "tieUpPercentForecast" numeric, "tieUpCost" numeric, "categoryForecast" numeric, "incrementalForecast" numeric, "incrementalForecastPercent" numeric, "purchaseQuantity" integer, "forecastCost" numeric, "forecastSales" numeric, ignition boolean, "COUNTRY" character varying) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
 BEGIN RETURN QUERY SELECT eh."eventDescription", 
 eo.page, 
 CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"
                    ELSE eo."pagePosition"
                END , 
 eod."comOfferCategory1" AS "commercialOfferItemClass1", 
 eo."offerNumber" AS "offerNo", 
 CASE 
    WHEN eo."isRewards" = true
    THEN CONCAT(eo."commercialOfferType", '-Loyal')
    ELSE eo."commercialOfferType"
END AS "commercialOfferType",
 eo."offerId",
 prod.sku,
 prod.brand,
 prod."partNo", prod.description, 
 CASE 
          WHEN    
        COALESCE(eod."group0Quantity", 0) > 0 OR
        COALESCE(eod."group1Quantity", 0) > 0 OR
        COALESCE(eod."group2Quantity", 0) > 0 OR
        COALESCE(eod."group3Quantity", 0) > 0 OR
        COALESCE(eod."group4Quantity", 0) > 0 OR
        COALESCE(eod."group5Quantity", 0) > 0 
             THEN 'Location'::text
          ELSE NULL::text
           END AS "TIEUP",
 Round(eod."everydayPriceGst",2),
 Round(eod."advertisedPriceGst",2), 
 eod."allocationGroup",
 eod."allocationType", 
 eod."group0Quantity", 
 eod."group1Quantity", 
 eod."group2Quantity", 
 eod."group3Quantity", 
 eod."group4Quantity",
 eod."group5Quantity", 
 Round(eod."totalTieUp",2), 
 CASE WHEN eod.categoryforecast = 0 THEN 0::NUMERIC(19,5) ELSE Round(CAST(eod."totalTieUp" AS NUMERIC(19,5)) / eod.categoryforecast * 100,2) END AS "tieUpPercentForecast", 
 Round(eod."tieUpCost",2), 
 Round(eod.categoryforecast,2) AS "categoryForecast", 
 Round(eod."incrementalForecast",2), 
 CASE WHEN eod."incrementalForecast" = 0 THEN 0::numeric WHEN eod.categoryforecast = 0 THEN 0::numeric ELSE Round(CAST(eod."incrementalForecast" AS numeric) / CAST(eod.categoryforecast AS numeric),2) END AS "incrementalForecastPercent", 
 eod."purchaseQuantity",
 Round(eod."forecastCost",2), 
 Round(eod."forecastSales",2),
 eo."isIntroPrice" AS ignition,
 eh."country" AS "COUNTRY"
 FROM public."tEvent" eh 
 INNER JOIN public."tEventOffer" eo 
 ON eh."eventId" = eo."eventId" 
 INNER JOIN public."tEventPage" ep 
 ON ep."eventId" = eo."eventId" 
 AND ep.page = eo.page 
 INNER JOIN public."tEventOfferDetail" eod
 ON eod."eventId" = eo."eventId" 
 AND eod.page = eo.page 
 AND eod."pagePosition" = eo."pagePosition"
 AND eod."offerNo" = eo."offerNumber"
 AND eod."offerId"::INTEGER = eo."offerId"
 INNER JOIN public."tProducts" prod
 ON eod.sku = prod.sku 
WHERE eh."eventId" = p_event_id 
 AND NOT (
                eh."eventType" = 'Retail Catalogue'
                AND eo."pagePosition" = 0
            )
AND ((eh."status" IN ('Open', 'Locked') AND eo."isOfferActive" = TRUE AND eod."isSkuActive" = TRUE) OR (eh."status" IN ('Completed', 'Cancelled')))
ORDER BY eo.page ASC, eo."pagePosition" ASC, eo."comOfferCategory1" ASC, eo."offerNumber" ASC, prod."partNo" ASC; END; 
$BODY$;