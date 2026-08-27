-- View: public.vwUpdHybExpComboDtlAU

-- DROP VIEW public."vwUpdHybExpComboDtlAU";

CREATE OR REPLACE VIEW public."vwUpdHybExpComboDtlAU"
 AS
 WITH base AS (
         SELECT eh."eventId",
            eoh.page,
            eoh."pagePosition",
            eoh."offerId",
            eoh."offerNumber",
            ot."offerTypeId",
            concat('C', 'AUS', 'E', eh."eventId", 'P', eoh.page, 'P',
                CASE
                    WHEN eoh."pagePosition" = 0 THEN eoh."offerId"
                    ELSE eoh."pagePosition"
                END, 'I', max(eoh."commercialOfferItemClass1"::text),
                CASE
                    WHEN ot."offerTypeId" = 3 THEN 'OT3CMB'::text
                    WHEN ot."offerTypeId" = 15 THEN 'OT15MULTILIST'::text
                    WHEN ot."offerTypeId" = 25 THEN 'OT25CMB'::text
                    ELSE NULL::text
                END, 'V', 1) AS "PROMOTION_CODE",
            concat('Selection_', eoh."offerNumber") AS "GROUP",
            string_agg(eod.sku::text, ','::text ORDER BY (eod.sku::text)) AS "PRODUCTS",
            eh."salesKeyword"::text AS "SALE_KEYWORDS"
           FROM "tEvent" eh
             JOIN "tEventOffer" eoh ON eh."eventId" = eoh."eventId" and eoh."isOfferActive"=true
             JOIN "tOfferType" ot ON upper(eoh."commercialOfferType"::text) = upper(ot."offerType"::text) AND eh.country::text = ot.country::text
             JOIN "tEventOfferDetail" eod ON eod."eventId" = eoh."eventId" AND eod.page = eoh.page AND eod."pagePosition" = eoh."pagePosition" AND eod."offerId" = eoh."offerId" AND eod."offerNo" = eoh."offerNumber" and eod."isSkuActive"=true
          WHERE eh.locked = true AND COALESCE(eoh."isNotAvailableOnline", false) = false AND eoh."advertisedPrice" > 0::numeric AND "left"(eh."eventType"::text, 3) <> 'LOY'::text AND eh.country::text = 'AU'::text AND (ot."offerTypeId" = ANY (ARRAY[3, 15, 25])) AND NOT (eh."eventType"::text = 'Retail Catalogue'::text AND eoh."pagePosition" = 0)
          GROUP BY eh."eventId", eoh.page, eoh."pagePosition", eoh."offerId", eoh."offerNumber", ot."offerTypeId", eh."salesKeyword"
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



