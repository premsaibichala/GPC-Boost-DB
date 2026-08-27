-- FUNCTION: public.spRetailPricingEPPOtIC(integer, integer, integer, character varying, character varying, character varying, character varying)

-- DROP FUNCTION IF EXISTS public."spRetailPricingEPPOtIC"(integer, integer, integer, character varying, character varying, character varying, character varying);

CREATE OR REPLACE FUNCTION public."spRetailPricingEPPOtIC"(
	p_eventid integer,
	p_page integer DEFAULT NULL::integer,
	p_pageposn integer DEFAULT NULL::integer,
	p_comoffertypeid character varying DEFAULT NULL::character varying,
	p_comofferic character varying DEFAULT NULL::character varying,
	p_criteria character varying DEFAULT NULL::character varying,
	p_fieldlist character varying DEFAULT '*'::character varying)
    RETURNS TABLE("EVENTDESC" character varying, "PAGE" integer, "PAGEPOSN" integer, "COMOFFERTYPE" character varying, "COMOFFERIC1" character varying, "PARTNO" character varying, "DESC" character varying, "BRAND" character varying, "SKU" character varying, "EDPRICEGST" numeric, "STARTDTE" date, "ENDDTE" date, "COMCATMAN" character varying, "OFFERNAME" character varying, "IC4" character varying, "OFFERTYPE" character varying, "SAVEPCT" numeric, "ADVPRICEGST" numeric, "CALCSAVEPCT" numeric, "CALCSAVEVAL" numeric, "TOTEDPRICEGST" numeric, "TOTADVPRICEGST" numeric, "TOTCALCSAVEVAL" numeric, "Ignition" numeric, "PRCONLY" boolean) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
                                                                                                                                                
DECLARE
    v_Sql TEXT;
    v_crit TEXT;
BEGIN
    -- Build the WHERE clause criteria
    v_crit := ' eh."eventId" = ' || p_EventId::TEXT;
    IF p_Page IS NOT NULL THEN
        v_crit := v_crit || ' AND eo."page" = ' || p_Page::TEXT;
    END IF;
    IF p_PagePosn IS NOT NULL THEN
        v_crit := v_crit || ' AND eo."pagePosition" = ' || p_PagePosn::TEXT;
    END IF;
    IF p_ComOfferTypeID IS NOT NULL AND p_ComOfferTypeID <> '' THEN
        v_crit := v_crit || ' AND ot_type."offerTypeId" IN (' || p_ComOfferTypeID || ')';
    END IF;
    IF p_ComOfferIC IS NOT NULL AND p_ComOfferIC <> '' THEN
        v_crit := v_crit || ' AND eo."commercialOfferItemClass1" = ''' || p_ComOfferIC || '''';
    END IF;
    IF p_criteria IS NOT NULL AND p_criteria <> '' THEN
        v_crit := v_crit || ' AND (' || p_criteria || ')';
    END IF;

    -- Build the dynamic SQL query with offer_totals
    v_Sql := 'WITH offer_totals AS (
        SELECT eod."offerId",
               Round(SUM(eod."advertisedPriceGst"),2) AS total_adv_price,
               Round(SUM(eod."everydayPriceGst"),2) AS total_ed_price
        FROM public."tEventOfferDetail" eod
        GROUP BY eod."offerId"
    )
    SELECT ' || p_FieldList || ' FROM (
        SELECT DISTINCT
            eh."eventDescription" AS "EVENTDESC",
            eo."page" AS "PAGE",
            CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"
                    ELSE eo."pagePosition"
                END  AS "PAGEPOSN",
            eo."offerType" AS "COMOFFERTYPE",
            eod."comOfferCategory1" AS "COMOFFERIC1",
            prod."partNo" AS "PARTNO",
            prod."description" AS "DESC",
            prod."brand" AS "BRAND",
            prod."sku" AS "SKU",
            Round(eod."everydayPriceGst",2) AS "EDPRICEGST",
            eh."startDate" AS "STARTDTE",
            eh."endDate" AS "ENDDTE",
            eo."commercialCategoryManager" AS "COMCATMAN",
            eo."offerName" AS "OFFERNAME",
            prod."itemClass4" AS "IC4",
            eo."commercialOfferType" AS "OFFERTYPE",
            Round(eo."savePercent",2) AS "SAVEPCT",
			CASE 
			WHEN eod."fromPriceIndicator"=true
			THEN   FLOOR(eod."advertisedPriceGst")
			ELSE
            Round(eod."advertisedPriceGst",2)
			END AS "ADVPRICEGST",
            Round(eod."calculatedSavePercentage",2) AS "CALCSAVEPCT",
            Round(eod."calculatedSaveValue",2) AS "CALCSAVEVAL",
            CASE
                WHEN eo."commercialOfferType" IN  (
        ''MULTI-BUY'',
        ''COMBO'',
        ''BUY X GET Y FREE'',
        ''COMBO(SKU LIST)'',
        ''PRICE ONLY (SKU LIST)'',
        ''MULTI-BUY (SKU LIST)'',
        ''PCT OFF RANGE (SKU LIST)'',
        ''COMBO-Loyal'',
        ''MULTI-BUY (SKU LIST)-Loyal'',
        ''MULTI-BUY-Loyal'',
        ''PCT OFF RANGE (SKU LIST)-Loyal''
    ) THEN COALESCE(ot_tot.total_ed_price,0)
                ELSE 0::NUMERIC
            END AS "TOTEDPRICEGST",
            CASE
                WHEN eo."commercialOfferType" IN(
        ''MULTI-BUY'',
        ''COMBO'',
        ''BUY X GET Y FREE'',
        ''COMBO(SKU LIST)'',
        ''PRICE ONLY (SKU LIST)'',
        ''MULTI-BUY (SKU LIST)'',
        ''PCT OFF RANGE (SKU LIST)'',
        ''COMBO-Loyal'',
        ''MULTI-BUY (SKU LIST)-Loyal'',
        ''MULTI-BUY-Loyal'',
        ''PCT OFF RANGE (SKU LIST)-Loyal''
    )  THEN COALESCE(ot_tot.total_adv_price,0)
                ELSE 0::NUMERIC
            END AS "TOTADVPRICEGST",
            CASE
                WHEN eo."commercialOfferType" IN (
        ''MULTI-BUY'',
        ''COMBO'',
        ''BUY X GET Y FREE'',
        ''COMBO(SKU LIST)'',
        ''PRICE ONLY (SKU LIST)'',
        ''MULTI-BUY (SKU LIST)'',
        ''PCT OFF RANGE (SKU LIST)'',
        ''COMBO-Loyal'',
        ''MULTI-BUY (SKU LIST)-Loyal'',
        ''MULTI-BUY-Loyal'',
        ''PCT OFF RANGE (SKU LIST)-Loyal''
    )  THEN Round(COALESCE(ot_tot.total_ed_price,0) - COALESCE(ot_tot.total_adv_price,0),2)
                ELSE 0::NUMERIC
            END AS "TOTCALCSAVEVAL",
            0::NUMERIC(19,5) AS "Ignition",
            eod."priceOnly" AS "PRCONLY"
        FROM "tEvent" eh
        INNER JOIN "tEventOffer" eo ON eh."eventId" = eo."eventId" AND eo."isOfferActive" = TRUE
        INNER JOIN "tEventOfferDetail" eod
            ON eo."offerId" = eod."offerId"
            AND eo."offerNumber" = eod."offerNo"
            AND eod."isSkuActive" = TRUE
           
        INNER JOIN "tProducts" prod ON eod."sku" = prod."sku"
        INNER JOIN "tOfferType" ot_type ON eo."OfferTypeId" = ot_type."offerTypeId" and eh."country"=ot_type."country"
        LEFT JOIN offer_totals ot_tot ON eo."offerId" = ot_tot."offerId"
        WHERE ' || v_crit || '
		AND NOT (eh."eventType"::text = ''Retail Catalogue''::text AND eo."pagePosition" = 0)
        AND ((eh."status" IN (''Open'', ''Locked'') AND eo."isOfferActive" = TRUE AND eod."isSkuActive" = TRUE) OR (eh."status" IN (''Completed'', ''Cancelled'')))
        
    ) s
    ORDER BY "PAGE", "PAGEPOSN", "COMOFFERIC1", "PARTNO";';                                                              
    -- Execute the dynamic SQL and return results                                                                                                    
    RETURN QUERY EXECUTE v_Sql;                                                                            
                                                                                                                      
END;                                                                                                                                                 
$BODY$;