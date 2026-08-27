-- View: public.vwUpdHybExpLoyBuyXGetYFreeAU

-- DROP VIEW public."vwUpdHybExpLoyBuyXGetYFreeAU";

CREATE OR REPLACE VIEW public."vwUpdHybExpLoyBuyXGetYFreeAU"
 AS
 SELECT DISTINCT concat('C', 'AUS', 'E', eo."eventId"::text, 'P', eo.page::text, 'P',
        CASE
            WHEN eo."pagePosition" = 0 THEN eo."offerId"::text
            ELSE eo."pagePosition"::text
        END, 'I', eo."commercialOfferItemClass1", 'OT5BXGY', 'V', 1) AS "PROMOTION_CODE",
    ot."hybrisLoyaltyStickerBackgroundColor" AS "STICKER_BGCOLOR",
    ot."hybrisLoyaltyStickerTextColor" AS "STICKER_COLOR",
    ot."hybrisLoyaltyStickerText" AS "STICKER_TEXT",
    ot."hybrisLoyaltyPillBackgroundColor" AS "PILL_BGCOLOR",
    ot."hybrisLoyaltyPillTextColor" AS "PILL_COLOR",
        CASE
            WHEN (eo."hybrisPillText"::text = ANY (ARRAY['As Advertised'::character varying::text, 'On Sale Now'::character varying::text])) OR "right"(eo."hybrisPillText"::text, 9) = 'Available'::text OR eo."hybrisPillText" IS NULL THEN ot."hybrisLoyaltyPillText"
            ELSE eo."hybrisPillText"
        END AS "PILL_TEXT",
    ot."hybrisActionBackgroundColor" AS "ACTION_BGCOLOR",
    ot."hybrisActionTextColor" AS "ACTION_COLOR",
    ot."hybrisActionText" AS "ACTION_TEXT",
    ot."hybrisLoyaltyDrMessageColor" AS "HEADER_COLOR",
    replace(COALESCE(eo."offerName", ''::character varying)::text, '"'::text, '""'::text) AS "PROMO_HEADER",
    ot."hybrisMessageColor" AS "MESSAGE_COLOR",
    replace(eo."offerName"::text, '"'::text, '""'::text) AS "PROMO_MESSAGE",
    'VIP'::text AS "PROMOTION_CLASS",
    NULL::text AS "PRICELIST_CODE",
    ot."hybrisLoyaltyCartMessage" AS "CART_MESSAGE",
    concat(to_char(ev."startDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."startTime"::text) AS "START_DATE",
    concat(to_char(ev."endDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."endTime"::text) AS "END_DATE",
    'default.png'::text AS "PROMO_IMAGE",
    ev."salesKeyword" AS "SALE_KEYWORDS"
   FROM "tEvent" ev
     JOIN "tEventOffer" eo ON ev."eventId" = eo."eventId" and eo."isOfferActive"=true
     JOIN "tOfferType" ot ON eo."commercialOfferType"::text = ot."offerType"::text AND ev.country::text = ot.country::text
     LEFT JOIN "tHybrisStickerText" hst ON eo."hybrisStickerText"::text = hst."hybrisStickerText"::text AND ev.country::text = hst.country::text
  WHERE ev.locked = true AND eo."isNotAvailableOnline" = false AND ot."offerTypeId" = 5 AND (eo."advertisedPrice" > 0::numeric OR eo."offerNumber" = 2) AND eo."isRewards" = true AND ev.country::text = 'AU'::text AND NOT (ev."eventType"::text = 'Retail Catalogue'::text AND eo."pagePosition" = 0);



