-- FUNCTION: public.get_edited_skus(integer, integer)

-- DROP FUNCTION IF EXISTS public.get_edited_skus(integer, integer);

CREATE OR REPLACE FUNCTION public.get_edited_skus(
	p_offer_id integer,
	p_offer_no integer)
    RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_skus TEXT;
BEGIN
    SELECT STRING_AGG(sku, ',')
    INTO v_skus
    FROM "tEventOfferDetail"
    WHERE "offerId" = p_offer_id
      AND "offerNo" = p_offer_no
      AND "isSkuEdited" = True
      AND "isSkuActive" =TRUE;

    RETURN v_skus;
END;
$BODY$;

