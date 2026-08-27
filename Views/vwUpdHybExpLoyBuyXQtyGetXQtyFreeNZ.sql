-- View: public.vwUpdHybExpLoyBuyXQtyGetXQtyFreeNZ

-- DROP VIEW public."vwUpdHybExpLoyBuyXQtyGetXQtyFreeNZ";

CREATE OR REPLACE VIEW public."vwUpdHybExpLoyBuyXQtyGetXQtyFreeNZ"
 AS
 SELECT DISTINCT concat('C', 'NZ', 'E', eo."eventId"::text, 'P', eo.page::text, 'P',
        CASE
            WHEN eo."pagePosition" = 0 THEN eo."offerId"::text
            ELSE eo."pagePosition"::text
        END, 'I', eo."commercialOfferItemClass1", 'OT17BXGX', 'S', (floor(eo."savePercent"::numeric / 5::numeric) * 5::numeric)::text, 'V', 1) AS "PROMOTION_CODE",
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
    to_char(ev."startDate" + COALESCE(ev."startTime"::time without time zone, '00:00:00'::time without time zone) - '02:00:00'::interval, 'DD-MM-YYYY HH24:MI:SS'::text) AS "START_DATE",
    to_char(ev."endDate" + COALESCE(ev."endTime"::time without time zone, '23:59:59'::time without time zone) - '02:00:00'::interval, 'DD-MM-YYYY HH24:MI:SS'::text) AS "END_DATE",
    'default.png'::text AS "PROMO_IMAGE",
    ( SELECT string_agg(eod.sku::text, ','::text ORDER BY (eod.sku::text)) AS string_agg
           FROM "tEventOfferDetail" eod
          WHERE eod."eventId" = eo."eventId" AND eod.page = eo.page AND eod."pagePosition" = eo."pagePosition" AND eod."offerId" = eo."offerId" AND eod."offerNo" = eo."offerNumber") AS "PRODUCTS",
    (eo."purchaseQuantity" + eo."freeQuantity"::numeric)::integer AS "QUANTITY1",
    eo."freeQuantity" AS "QUANTITY2",
    ev."salesKeyword" AS "SALE_KEYWORDS"
   FROM "tEvent" ev
     JOIN "tEventOffer" eo ON ev."eventId" = eo."eventId" and eo."isOfferActive"=true
     JOIN "tOfferType" ot ON eo."commercialOfferType"::text = ot."offerType"::text AND ev.country::text = ot.country::text
     LEFT JOIN "tHybrisStickerText" hst ON eo."hybrisStickerText"::text = hst."hybrisStickerText"::text AND ev.country::text = hst.country::text
  WHERE ev.locked = true AND eo."isNotAvailableOnline" = false AND ot."offerTypeId" = 17 AND eo."advertisedPrice" > 0::numeric AND eo."isRewards" = true AND ev.country::text = 'NZ'::text AND NOT (ev."eventType"::text = 'Retail Catalogue'::text AND eo."pagePosition" = 0);



