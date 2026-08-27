-- FUNCTION: public.fn_get_offer_products(integer)

-- DROP FUNCTION IF EXISTS public.fn_get_offer_products(integer);

CREATE OR REPLACE FUNCTION public.fn_get_offer_products(
	event_id integer)
    RETURNS TABLE(offerid integer, brand text, partno text, itemclass1 text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
    RETURN QUERY
    SELECT 
        e."offerId",

        -- brand logic
        CASE 
            WHEN eo."isOfferActive" = FALSE 
                THEN NULL
            WHEN COUNT(DISTINCT p."brand") = 1 
                THEN MAX(p."brand")
            ELSE 'Multiple'
        END AS brand,

        -- part number logic
        CASE 
            WHEN eo."isOfferActive" = FALSE 
                THEN NULL
            WHEN COUNT(DISTINCT p."partNo") = 1
                THEN MAX(p."partNo")
            ELSE 'SKU List'
        END AS partNo,

        -- itemClass1 logic
        CASE 
            WHEN eo."isOfferActive" = FALSE
                THEN NULL
            WHEN COUNT(DISTINCT p."sku") = 1 
                THEN MAX(e."comOfferCategory1")
            ELSE STRING_AGG(DISTINCT p."itemClass1", ', ')
        END AS itemClass1

    FROM "tEventOfferDetail" e
    JOIN "tEvent" t ON t."eventId" = e."eventId"
    JOIN "tEventOffer" eo ON e."offerId" = eo."offerId"
    LEFT JOIN "tProducts" p ON e."sku" = p."sku" 
        AND p."country" = t."country"
        AND p."isActive" = TRUE
    WHERE e."eventId" = event_id
    GROUP BY e."offerId", eo."isOfferActive"
    ORDER BY e."offerId";
END;
$BODY$;
