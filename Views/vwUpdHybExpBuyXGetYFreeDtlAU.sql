-- View: public.vwUpdHybExpBuyXGetYFreeDtlAU

-- DROP VIEW public."vwUpdHybExpBuyXGetYFreeDtlAU";

CREATE OR REPLACE VIEW public."vwUpdHybExpBuyXGetYFreeDtlAU"
 AS
 SELECT DISTINCT concat('C', 'AUS', 'E', eoh_new."eventId", 'P', eoh_new.page, 'P',
        CASE
            WHEN eoh_new."pagePosition" = 0 THEN eoh_new."offerId"
            ELSE eoh_new."pagePosition"
        END, 'I', eoh_new."commercialOfferItemClass1", 'OT5BXGY', 'V', 1) AS "PROMOTION_CODE",
    concat('Selection_'::text, eoh_new."offerNumber") AS "GROUP",
    ( SELECT string_agg(t1.sku::text, ','::text ORDER BY (t1.sku::text)) AS string_agg
           FROM "tEventOfferDetail" t1
          WHERE t1."eventId" = eoh_new."eventId" AND t1.page = eoh_new.page AND t1."pagePosition" = eoh_new."pagePosition" AND t1."offerId" = eoh_new."offerId" AND t1."offerNo" = eoh_new."offerNumber") AS "PRODUCTS",
        CASE
            WHEN eoh_new."offerNumber" = 2 THEN 'True'::text
            ELSE 'False'::text
        END AS "IS_TARGET_GROUP",
    eh_new."salesKeyword" AS "SALE_KEYWORDS"
   FROM "tEvent" eh_new
     JOIN "tEventOffer" eoh_new ON eh_new."eventId" = eoh_new."eventId" and eoh_new."isOfferActive"=true
     JOIN "tOfferType" lbot_new ON upper(eoh_new."commercialOfferType"::text) = upper(lbot_new."offerType"::text) AND eh_new.country::text = lbot_new.country::text
     LEFT JOIN "tHybrisStickerText" lbhst_new ON eoh_new."hybrisStickerText"::text = lbhst_new."hybrisStickerText"::text AND eh_new.country::text = lbhst_new.country::text
  WHERE eh_new.locked = true AND COALESCE(eoh_new."isNotAvailableOnline", false) = false AND lbot_new."offerTypeId" = 5 AND (eoh_new."advertisedPrice" > 0::numeric OR eoh_new."offerNumber" = 2) AND "left"(eh_new."eventType"::text, 3) <> 'LOY'::text AND eh_new.country::text = 'AU'::text AND NOT (eh_new."eventType"::text = 'Retail Catalogue'::text AND eoh_new."pagePosition" = 0);



