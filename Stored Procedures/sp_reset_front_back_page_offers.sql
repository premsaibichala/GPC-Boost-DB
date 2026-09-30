-- PROCEDURE: public.sp_reset_front_back_page_offers(integer)

-- DROP PROCEDURE IF EXISTS public.sp_reset_front_back_page_offers(integer);

CREATE OR REPLACE PROCEDURE public.sp_reset_front_back_page_offers(
	IN p_event_id integer)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_offer_ids integer[];
    v_last_page integer;
BEGIN
    -- Offers currently sitting on a page whose description is Front Page / Back Page.
    SELECT array_agg(eo."offerId")
    INTO v_offer_ids
    FROM "tEventOffer" eo
    JOIN "tEventPage" ep
      ON ep."eventId" = eo."eventId"
     AND ep."page" = eo."page"
    WHERE eo."eventId" = p_event_id
      AND ep."pageDescription" IN ('Front Page', 'Back Page');

    IF v_offer_ids IS NULL THEN
        RETURN;
    END IF;

    SELECT MAX(mh."pageId")
    INTO v_last_page
    FROM "tMudMapHeader" mh
    WHERE mh."eventId" = p_event_id;

    -- Move them to unassigned (page 0, position 0).
    UPDATE "tEventOffer" AS eo
    SET "page" = 0,
        "pagePosition" = 0
    WHERE eo."eventId" = p_event_id
      AND eo."offerId" = ANY (v_offer_ids);

    -- Keep tEventOfferDetail (per-SKU rows) in sync with the header move above.
    UPDATE "tEventOfferDetail" AS eod
    SET "page" = 0,
        "pagePosition" = 0
    WHERE eod."eventId" = p_event_id
      AND eod."offerId" = ANY (v_offer_ids);
	  
	  UPDATE public."tEventOfferSearchHistory" AS eod
    SET "pageId" = 0,
        "positionId" = 0
    WHERE eod."eventId" = p_event_id
      AND eod."eventOfferId" = ANY (v_offer_ids);

    -- Reset the corresponding bids back to pending approval.
    UPDATE "tBids" AS b
    SET "isApproved" = false
    WHERE b."eventId" = p_event_id
      AND b."offerId" = ANY (v_offer_ids);

    IF v_last_page IS NOT NULL THEN
        UPDATE "tMudMapDetail" AS md
        SET "eventOfferId" = NULL,
            "offerName" = NULL,
            "offerType" = NULL,
            "offerTypeId" = NULL,
            "everydayPrice" = NULL,
            "advertisedPrice" = NULL,
            "saveValue" = NULL,
            "savePercent" = NULL,
            "message" = NULL,
            "partNumber" = NULL,
            "requiredQuantity" = NULL,
            "purchaseQuantity" = NULL,
            "freeQuantity" = NULL,
            "isReserved" = false,
            "clearance" = false,
            "multiBuy" = false,
            "combo" = false,
            "new" = false,
            "loyality" = false
        WHERE md."eventId" = p_event_id
          AND md."pageId" IN (1, v_last_page)
          AND md."eventOfferId" = ANY (v_offer_ids);
    END IF;
END;
$BODY$;

