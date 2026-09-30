-- PROCEDURE: public.sp_undo_bid_offer(integer, integer, text)

-- DROP PROCEDURE IF EXISTS public.sp_undo_bid_offer(integer, integer, text);

CREATE OR REPLACE PROCEDURE public.sp_undo_bid_offer(
	IN p_bid_id integer,
	IN p_offer_id integer,
	IN p_updated_by text)
LANGUAGE 'plpgsql'
AS $BODY$
BEGIN
    -- Remove the mud map cell that was displaying this offer.
    DELETE FROM "tMudMapDetail"
    WHERE "eventOfferId" = p_offer_id;

    -- Remove the offer's detail and header records.
    DELETE FROM "tEventOfferDetail"
    WHERE "offerId" = p_offer_id;

    DELETE FROM "tEventOffer"
    WHERE "offerId" = p_offer_id;

    -- Reset the bid back to unapproved / unselected.
    UPDATE "tBids"
    SET "isApproved" = false,
        "pageSelection" = NULL,
        "updatedBy" = p_updated_by,
        "updatedAt" = now()
    WHERE "bidId" = p_bid_id;
END;
$BODY$;