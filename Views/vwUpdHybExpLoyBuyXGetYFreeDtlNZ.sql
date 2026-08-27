-- View: public.vwUpdHybExpLoyBuyXGetYFreeDtlNZ

-- DROP VIEW public."vwUpdHybExpLoyBuyXGetYFreeDtlNZ";

CREATE OR REPLACE VIEW public."vwUpdHybExpLoyBuyXGetYFreeDtlNZ"
 AS
 SELECT DISTINCT concat('C', 'NZ', 'E', eo."eventId"::text, 'P', eo.page::text, 'P',
        CASE
            WHEN eo."pagePosition" = 0 THEN eo."offerId"::text
            ELSE eo."pagePosition"::text
        END, 'I', eo."commercialOfferItemClass1", 'OT5BXGY', 'V', 1) AS "PROMOTION_CODE",
    concat('Selection_'::text, eo."offerNumber") AS "GROUP",
    ( SELECT string_agg(eod.sku::text, ','::text ORDER BY (eod.sku::text)) AS string_agg
           FROM "tEventOfferDetail" eod
          WHERE eod."eventId" = eo."eventId" AND eod.page = eo.page AND eod."pagePosition" = eo."pagePosition" AND eod."offerId" = eo."offerId" AND eod."offerNo" = eo."offerNumber" and eod."isSkuActive"=true) AS "PRODUCTS",
        CASE
            WHEN eo."offerNumber" = 2 THEN 'True'::text
            ELSE 'False'::text
        END AS "IS_TARGET_GROUP",
    ev."salesKeyword" AS "SALE_KEYWORDS"
   FROM "tEvent" ev
     JOIN "tEventOffer" eo ON ev."eventId" = eo."eventId" and eo."isOfferActive"=true
     JOIN "tOfferType" ot ON eo."commercialOfferType"::text = ot."offerType"::text AND ev.country::text = ot.country::text
     LEFT JOIN "tHybrisStickerText" hst ON eo."hybrisStickerText"::text = hst."hybrisStickerText"::text AND ev.country::text = hst.country::text
  WHERE ev.locked = true AND eo."isNotAvailableOnline" = false AND ot."offerTypeId" = 5 AND (eo."advertisedPrice" > 0::numeric OR eo."offerNumber" = 2) AND eo."isRewards" = true AND ev.country::text = 'NZ'::text AND NOT (ev."eventType"::text = 'Retail Catalogue'::text AND eo."pagePosition" = 0);



