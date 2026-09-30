
CREATE OR REPLACE PROCEDURE public.sp_undo_bid_offer(
    IN p_offer_ids int)
LANGUAGE 'plpgsql'
AS $BODY$
BEGIN
    -- Move the offers back to unassigned (page 0, position 0).
    UPDATE "tEventOffer"
    SET "page" = 0,
        "pagePosition" = 0
    WHERE "offerId" = p_offer_ids;
    UPDATE "tEventOfferDetail"
    SET "page" = 0,
        "pagePosition" = 0
    WHERE "offerId" = p_offer_ids;
    UPDATE "tEventOfferSearchHistory"
    SET "pageId" = 0,
        "positionId" = 0
    WHERE "eventOfferId" = p_offer_ids;
    -- Clear the mud map cells that were displaying these offers.
    UPDATE "tMudMapDetail" 
    SET
        "eventOfferId"     = NULL,
        "offerName"        = NULL,
        "offerType"        = NULL,
        "everydayPrice"    = NULL,
        "isReserved"       = FALSE,
        "advertisedPrice"  = NULL,
        "saveValue"        = NULL,
        "savePercent"      = NULL,
        "message"          = NULL,
        "partNumber"       = NULL,
        "clearance"        = NULL,
        "multiBuy"         = NULL,
        "combo"            = NULL,
        "new"              = NULL,
        "loyality"         = NULL,
        "isActive"         = FALSE,
        "userName"         = NULL,
        "requiredQuantity" = NULL,
        "fromPrice"        = NULL,
        "purchaseQuantity" = NULL,
        "freeQuantity"     = NULL,
        "lockedAt"         = NULL,
        "offerTypeId"      = NULL
    WHERE "eventOfferId" = p_offer_ids;
END;
$BODY$;
 