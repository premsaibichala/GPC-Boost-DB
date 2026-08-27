-- FUNCTION: public.spRetailPricingByEventID(integer)

-- DROP FUNCTION IF EXISTS public."spRetailPricingByEventID"(integer);

CREATE OR REPLACE FUNCTION public."spRetailPricingByEventID"(
	p_eventid integer)
    RETURNS TABLE("EVENTDESC" character varying, "PAGE" integer, "PAGEPOSN" integer, "COMOFFERTYPE" character varying, "COMOFFERIC1" character varying, "PARTNO" character varying, "DESC" character varying, "BRAND" character varying, "SKU" character varying, "EDPRICEGST" numeric, "STARTDTE" date, "ENDDTE" date, "COMCATMAN" character varying, "OFFERNAME" character varying, "IC4" character varying, "OFFERTYPE" character varying, "SAVEPCT" numeric, "ADVPRICEGST" numeric, "Ignition" text, "TOTEDPRICEGST" numeric, "TOTADVPRICEGST" numeric, "TOTCALCSAVEVAL" numeric, "CALCSAVEPCT" numeric, "PRCONLY" boolean, "$SAVE" numeric, "Image Reference" character varying) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
    RETURN QUERY
    WITH offer_totals AS (
        SELECT
            eod."offerId",
            Round(SUM(eod."advertisedPriceGst"),2) AS total_adv_price,
            Round(SUM(eod."everydayPriceGst"),2) AS total_ed_price
        FROM public."tEventOfferDetail" eod
        GROUP BY eod."offerId"
    ),
    base_query AS (
        SELECT
            e."eventDescription" AS "EVENTDESC",
            eo."page" AS "PAGE",
            CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"
                    ELSE eo."pagePosition"
                END  AS "PAGEPOSN",
           CASE 
    WHEN eo."isRewards" = true
    THEN CONCAT(eo."commercialOfferType", '-Loyal')
    ELSE eo."commercialOfferType"
END AS "COMOFFERTYPE",
            eod."comOfferCategory1" AS "COMOFFERIC1",
            prod."partNo" AS "PARTNO",
            prod."description" AS "DESC",
            prod."brand" AS "BRAND",
            prod."sku" AS "SKU",
            eod."everydayPriceGst" AS "EDPRICEGST",
            e."startDate" AS "STARTDTE",
            e."endDate" AS "ENDDTE",
            eo."commercialCategoryManager" AS "COMCATMAN",
            eo."offerName" AS "OFFERNAME",
            prod."itemClass4" AS "IC4",
            eo."offerType" AS "OFFERTYPE",
           Round( eo."savePercent",2) AS "SAVEPCT",
            Round(eod."advertisedPriceGst",2) AS "ADVPRICEGST",
            FALSE::text AS "Ignition",
            CASE 
                WHEN eo."OfferTypeId" IN (4,3,5,25,23,15,6,103,115,104,106) THEN COALESCE(ot.total_ed_price,0)
                ELSE 0::NUMERIC
            END AS "TOTEDPRICEGST",
            CASE 
                WHEN eo."OfferTypeId" IN (3,5,25,23,15,6,103,115,104,106) THEN COALESCE(ot.total_adv_price,0)
                 WHEN eo."OfferTypeId" IN (4) THEN round(COALESCE(ot.total_adv_price,0)*eo."requiredQuantity",2)
               
				ELSE 0::NUMERIC
            END AS "TOTADVPRICEGST",
            CASE 
                WHEN eo."commercialOfferType" IN ('MULTI-BUY','COMBO','BUY X GET Y FREE','COMBO(SKU LIST)','PRICE ONLY (SKU LIST)','MULTI-BUY (SKU LIST)','PCT OFF RANGE (SKU LIST)','COMBO-Loyal','MULTI-BUY (SKU LIST)-Loyal','MULTI-BUY-Loyal','PCT OFF RANGE (SKU LIST)-Loyal') THEN Round(COALESCE(ot.total_ed_price,0) - COALESCE(ot.total_adv_price,0),2)
                ELSE 0::NUMERIC
            END AS "TOTCALCSAVEVAL",
            Round(eod."calculatedSavePercentage",2) AS "CALCSAVEPCT",
            eod."priceOnly" AS "PRCONLY",
            Round(eo."saveValue",2) AS "$SAVE",
			eo."imageReference" as "Image Reference"
        FROM "tEvent" e
        INNER JOIN "tEventOffer" eo
            ON e."eventId" = eo."eventId"
        INNER JOIN "tEventOfferDetail" eod
            ON eo."offerId" = eod."offerId"
            AND eo."offerNumber" = eod."offerNo"
            AND eo."page" = eod."page"
            AND eo."pagePosition" = eod."pagePosition"
          
        INNER JOIN "tProducts" prod
            ON eod."sku" = prod."sku"
        LEFT JOIN offer_totals ot
            ON eo."offerId" = ot."offerId" 
        WHERE eo."eventId" = p_eventid
		AND NOT (
                e."eventType" = 'Retail Catalogue'
                AND eo."pagePosition" = 0
            )
	AND ((e."status" IN ('Open', 'Locked') AND eo."isOfferActive" = TRUE AND eod."isSkuActive" = TRUE) OR (e."status" IN ('Completed', 'Cancelled')))
    )
    SELECT * 
    FROM base_query
    ORDER BY "PAGE", "PAGEPOSN", "COMOFFERIC1", "PARTNO";
END;
$BODY$;