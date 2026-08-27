-- View: public.vwUpdHybExpBuyXGetYFreeNZ

-- DROP VIEW public."vwUpdHybExpBuyXGetYFreeNZ";

CREATE OR REPLACE VIEW public."vwUpdHybExpBuyXGetYFreeNZ"
 AS
 SELECT DISTINCT concat('C', 'NZ', 'E', eoh_new."eventId", 'P', eoh_new.page, 'P',
        CASE
            WHEN eoh_new."pagePosition" = 0 THEN eoh_new."offerId"
            ELSE eoh_new."pagePosition"
        END, 'I', eoh_new."commercialOfferItemClass1", 'OT5BXGY', 'V', 1) AS "PROMOTION_CODE",
    lbot_new."hybrisDefaultStickerBackgroundColor" AS "STICKER_BGCOLOR",
    lbot_new."hybrisDefaultStickerTextColor" AS "STICKER_COLOR",
    lbot_new."hybrisDefaultStickerText" AS "STICKER_TEXT",
    lbot_new."hybrisPillBackgroundColor" AS "PILL_BGCOLOR",
    lbot_new."hybrisPillTextColor" AS "PILL_COLOR",
        CASE
            WHEN eoh_new."hybrisCommercialGroupText" IS NULL THEN lbot_new."hybrisDefaultPillText"
            ELSE eoh_new."hybrisCommercialGroupText"
        END AS "PILL_TEXT",
    lbot_new."hybrisActionBackgroundColor" AS "ACTION_BGCOLOR",
    lbot_new."hybrisActionTextColor" AS "ACTION_COLOR",
    lbot_new."hybrisActionText" AS "ACTION_TEXT",
    lbot_new."hybrisDrMessageColor" AS "HEADER_COLOR",
    replace(COALESCE(eoh_new."offerName", ''::character varying)::text, '"'::text, '""'::text) AS "PROMO_HEADER",
    lbot_new."hybrisMessageColor" AS "MESSAGE_COLOR",
    replace(COALESCE(eoh_new."offerName", ''::character varying)::text, '"'::text, '""'::text) AS "PROMO_MESSAGE",
    'FG'::text AS "PROMOTION_CLASS",
    NULL::text AS "PRICELIST_CODE",
    lbot_new."hybrisCartMessage" AS "CART_MESSAGE",
    to_char(eh_new."startDate" + COALESCE(eh_new."startTime"::time without time zone, '00:00:00'::time without time zone) - '02:00:00'::interval, 'DD-MM-YYYY HH24:MI:SS'::text) AS "START_DATE",
    to_char(eh_new."endDate" + COALESCE(eh_new."endTime"::time without time zone, '23:59:59'::time without time zone) - '02:00:00'::interval, 'DD-MM-YYYY HH24:MI:SS'::text) AS "END_DATE",
    'default.png'::text AS "PROMO_IMAGE",
    eh_new."salesKeyword" AS "SALE_KEYWORDS"
   FROM "tEvent" eh_new
     JOIN "tEventOffer" eoh_new ON eh_new."eventId" = eoh_new."eventId" and eoh_new."isOfferActive"=true
     JOIN "tOfferType" lbot_new ON upper(eoh_new."commercialOfferType"::text) = upper(lbot_new."offerType"::text) AND eh_new.country::text = lbot_new.country::text
     LEFT JOIN "tHybrisStickerText" lbhst_new ON eoh_new."hybrisStickerText"::text = lbhst_new."hybrisStickerText"::text AND eh_new.country::text = lbhst_new.country::text
  WHERE eh_new.locked = true AND COALESCE(eoh_new."isNotAvailableOnline", false) = false AND lbot_new."offerTypeId" = 5 AND (eoh_new."advertisedPrice" > 0::numeric OR eoh_new."offerNumber" = 2) AND "left"(eh_new."eventType"::text, 3) <> 'LOY'::text AND eh_new.country::text = 'NZ'::text AND NOT (eh_new."eventType"::text = 'Retail Catalogue'::text AND eoh_new."pagePosition" = 0);



