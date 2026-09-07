 -- FUNCTION: public.has_future_rrp(integer)
 
-- DROP FUNCTION IF EXISTS public.has_future_rrp(integer);
 
CREATE OR REPLACE FUNCTION public.has_future_rrp(
	p_offer_id integer)
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
          AND "isSkuActive" = TRUE
          AND "futureEdPrice" IS NOT NULL
          AND "futureEdEffectiveDate" IS NOT NULL
    );
END;
$BODY$;

