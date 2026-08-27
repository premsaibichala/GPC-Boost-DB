-- View: public.vwUpdHybExpComboAU

-- DROP VIEW public."vwUpdHybExpComboAU";

CREATE OR REPLACE VIEW public."vwUpdHybExpComboAU"
 AS
 SELECT DISTINCT concat('C', 'AUS', 'E', eoh_new."eventId", 'P', eoh_new.page, 'P',
        CASE
            WHEN eoh_new."pagePosition" = 0 THEN eoh_new."offerId"
            ELSE eoh_new."pagePosition"
        END, 'I', eoh_new."commercialOfferItemClass1",
        CASE lbot_new."offerTypeId"
            WHEN 3 THEN 'OT3CMB'::text
            WHEN 15 THEN 'OT15MULTILIST'::text
            WHEN 25 THEN 'OT25CMB'::text
            ELSE NULL::text
        END, 'V', 1) AS "PROMOTION_CODE",
        CASE
            WHEN lbhst_new."hybrisStickerText" IS NOT NULL THEN lbhst_new."hybrisStickerBackgroundColor"
            ELSE lbot_new."hybrisDefaultStickerBackgroundColor"
        END AS "STICKER_BGCOLOR",
        CASE
            WHEN lbhst_new."hybrisStickerText" IS NOT NULL THEN lbhst_new."hybrisStickerTextColor"
            ELSE lbot_new."hybrisDefaultStickerTextColor"
        END AS "STICKER_COLOR",
        CASE
            WHEN lbhst_new."hybrisStickerText" IS NOT NULL THEN lbhst_new."hybrisStickerText"
            ELSE lbot_new."hybrisDefaultStickerText"
        END AS "STICKER_TEXT",
    lbot_new."hybrisPillBackgroundColor" AS "PILL_BGCOLOR",
    lbot_new."hybrisPillTextColor" AS "PILL_COLOR",
        CASE
            WHEN eoh_new."hybrisPillText" IS NULL THEN lbot_new."hybrisDefaultPillText"
            ELSE eoh_new."hybrisPillText"
        END AS "PILL_TEXT",
    lbot_new."hybrisActionBackgroundColor" AS "ACTION_BGCOLOR",
    lbot_new."hybrisActionTextColor" AS "ACTION_COLOR",
    lbot_new."hybrisActionText" AS "ACTION_TEXT",
    lbot_new."hybrisDrMessageColor" AS "HEADER_COLOR",
    replace(COALESCE(eoh_new."offerName", ''::character varying)::text, '"'::text, '""'::text) AS "PROMO_HEADER",
    lbot_new."hybrisMessageColor" AS "MESSAGE_COLOR",
    replace(COALESCE(eoh_new."offerName", ''::character varying)::text, '"'::text, '"Combo Deal"'::text) AS "PROMO_MESSAGE",
    'CMB'::text AS "PROMOTION_CLASS",
    NULL::text AS "PRICELIST_CODE",
    lbot_new."hybrisCartMessage" AS "CART_MESSAGE",
    concat(to_char(eh_new."startDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', COALESCE(eh_new."startTime", '00:00:00'::time without time zone)) AS "START_DATE",
    concat(to_char(eh_new."endDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', COALESCE(eh_new."endTime", '23:59:59'::time without time zone)) AS "END_DATE",
    'default.png'::text AS "PROMO_IMAGE",
        CASE
            WHEN lbot_new."offerTypeId" = 3 THEN sum(round(eoh_new."advertisedPriceGst", 2)) OVER (PARTITION BY eoh_new."offerId")
            WHEN lbot_new."offerTypeId" = 15 THEN round(eoh_new."totalMultiBuyPrice", 2)
            WHEN lbot_new."offerTypeId" = 25 THEN sum(round(eoh_new."advertisedPriceGst", 2)) OVER (PARTITION BY eoh_new."offerId")
            ELSE NULL::numeric
        END AS "VALUE",
    eh_new."salesKeyword" AS "SALE_KEYWORDS"
   FROM "tEvent" eh_new
     JOIN "tEventOffer" eoh_new ON eh_new."eventId" = eoh_new."eventId" and eoh_new."isOfferActive"=true
     JOIN "tOfferType" lbot_new ON upper(eoh_new."commercialOfferType"::text) = upper(lbot_new."offerType"::text) AND eh_new.country::text = lbot_new.country::text
     LEFT JOIN "tHybrisStickerText" lbhst_new ON eoh_new."hybrisStickerText"::text = lbhst_new."hybrisStickerText"::text AND eh_new.country::text = lbhst_new.country::text
  WHERE eh_new.locked = true AND COALESCE(eoh_new."isNotAvailableOnline", false) = false AND (lbot_new."offerTypeId" = ANY (ARRAY[3, 15, 25])) AND eoh_new."advertisedPrice" > 0::numeric AND "left"(eh_new."eventType"::text, 3) <> 'LOY'::text AND eh_new.country::text = 'AU'::text AND NOT (eh_new."eventType"::text = 'Retail Catalogue'::text AND eoh_new."pagePosition" = 0);



