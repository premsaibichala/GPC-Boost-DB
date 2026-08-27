-- View: public.vwUpdHybExpLoyComboDtlNZ

-- DROP VIEW public."vwUpdHybExpLoyComboDtlNZ";

CREATE OR REPLACE VIEW public."vwUpdHybExpLoyComboDtlNZ"
 AS
 WITH base AS (
         SELECT ev."eventId",
            eo.page,
            eo."pagePosition",
            eo."offerId",
            eo."offerNumber",
            ot."offerTypeId",
            concat('C', 'NZ', 'E', ev."eventId"::text, 'P', eo.page::text, 'P',
                CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"::text
                    ELSE eo."pagePosition"::text
                END, 'I', max(eo."commercialOfferItemClass1"::text),
                CASE
                    WHEN ot."offerTypeId" = ANY (ARRAY[3, 103]) THEN 'OT3CMB'::text
                    WHEN ot."offerTypeId" = ANY (ARRAY[15, 115]) THEN 'OT15MULTILIST'::text
                    WHEN ot."offerTypeId" = 25 THEN 'OT25CMB'::text
                    ELSE NULL::text
                END, 'V', 1) AS "PROMOTION_CODE",
            concat('Selection_', eo."offerNumber") AS "GROUP",
            string_agg(eod.sku::text, ','::text ORDER BY (eod.sku::text)) AS "PRODUCTS",
            ev."salesKeyword"::text AS "SALE_KEYWORDS"
           FROM "tEvent" ev
             JOIN "tEventOffer" eo ON ev."eventId" = eo."eventId" and eo."isOfferActive"=true
             JOIN "tOfferType" ot ON eo."commercialOfferType"::text = ot."offerType"::text AND ev.country::text = ot.country::text
             LEFT JOIN "tHybrisStickerText" hst ON eo."hybrisStickerText"::text = hst."hybrisStickerText"::text AND ev.country::text = hst.country::text
             JOIN "tEventOfferDetail" eod ON eod."eventId" = eo."eventId" AND eod.page = eo.page AND eod."pagePosition" = eo."pagePosition" AND eod."offerId" = eo."offerId" AND eod."offerNo" = eo."offerNumber" and eod."isSkuActive"=true
          WHERE ev.locked = true AND eo."isNotAvailableOnline" = false AND eo."advertisedPrice" > 0::numeric AND ev.country::text = 'NZ'::text AND eo."isRewards" = true AND (ot."offerTypeId" = ANY (ARRAY[3, 103, 15, 115, 25]))
          GROUP BY ev."eventId", eo.page, eo."pagePosition", eo."offerId", eo."offerNumber", ot."offerTypeId", ev."salesKeyword"
        ), exploded AS (
         SELECT b."eventId",
            b.page,
            b."pagePosition",
            b."offerId",
            b."offerNumber",
            b."offerTypeId",
            b."PROMOTION_CODE",
            b."GROUP",
            b."SALE_KEYWORDS",
            sku_single.sku_single
           FROM base b
             CROSS JOIN LATERAL unnest(string_to_array(b."PRODUCTS", ','::text)) sku_single(sku_single)
        ), exploded_rn AS (
         SELECT exploded."eventId",
            exploded.page,
            exploded."pagePosition",
            exploded."offerId",
            exploded."offerNumber",
            exploded."offerTypeId",
            exploded."PROMOTION_CODE",
            exploded."GROUP",
            exploded."SALE_KEYWORDS",
            exploded.sku_single,
            row_number() OVER (PARTITION BY exploded."eventId", exploded.page, exploded."pagePosition", exploded."offerId", exploded."offerNumber", exploded."offerTypeId" ORDER BY exploded.sku_single) AS rn
           FROM exploded
        ), chunked AS (
         SELECT exploded_rn."eventId",
            exploded_rn.page,
            exploded_rn."pagePosition",
            exploded_rn."offerId",
            exploded_rn."offerNumber",
            exploded_rn."offerTypeId",
            exploded_rn."PROMOTION_CODE",
            exploded_rn."GROUP",
            exploded_rn."SALE_KEYWORDS",
            floor(((exploded_rn.rn - 1) / 2000)::double precision)::integer AS chunk_index,
            string_agg(exploded_rn.sku_single, ','::text ORDER BY exploded_rn.sku_single) AS "PRODUCTS"
           FROM exploded_rn
          GROUP BY exploded_rn."eventId", exploded_rn.page, exploded_rn."pagePosition", exploded_rn."offerId", exploded_rn."offerNumber", exploded_rn."offerTypeId", exploded_rn."PROMOTION_CODE", exploded_rn."GROUP", exploded_rn."SALE_KEYWORDS", (floor(((exploded_rn.rn - 1) / 2000)::double precision))
        )
 SELECT
        CASE
            WHEN chunk_index = 0 THEN "PROMOTION_CODE"
            ELSE ("PROMOTION_CODE" || '.'::text) || chunk_index::text
        END AS "PROMOTION_CODE",
    "GROUP",
    "PRODUCTS",
    "SALE_KEYWORDS"
   FROM chunked;



