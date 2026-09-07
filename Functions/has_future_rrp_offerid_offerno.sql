-- FUNCTION: public.has_future_rrp_offerid_offerno(integer, integer)
 
-- DROP FUNCTION IF EXISTS public.has_future_rrp_offerid_offerno(integer, integer);
 
CREATE OR REPLACE FUNCTION public.has_future_rrp_offerid_offerno(
	p_offer_id integer,
	p_offer_no integer)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM "tEventOfferDetail"
        WHERE "offerId" = p_offer_id
		  AND "offerNo" = p_offer_no
          AND "isSkuActive" = TRUE
          AND "futureEdPrice" IS NOT NULL
          AND "futureEdEffectiveDate" IS NOT NULL
    );
END;
$BODY$;

