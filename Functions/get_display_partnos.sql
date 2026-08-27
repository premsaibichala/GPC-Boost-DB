-- FUNCTION: public.get_display_partnos(integer)

-- DROP FUNCTION IF EXISTS public.get_display_partnos(integer);

CREATE OR REPLACE FUNCTION public.get_display_partnos(
	p_offer_id integer)
    RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_partnos TEXT;
BEGIN
    SELECT STRING_AGG("partNo", ', ')
    INTO v_partnos
    FROM public."tEventOfferDetail"
    WHERE "offerId" = p_offer_id
      AND "displayIndicator" = TRUE
      AND "isSkuActive" = TRUE;

    RETURN v_partnos;
END;
$BODY$;

