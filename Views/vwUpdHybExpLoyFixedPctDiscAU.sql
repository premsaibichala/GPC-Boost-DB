-- View: public.vwUpdHybExpLoyFixedPctDiscAU

-- DROP VIEW public."vwUpdHybExpLoyFixedPctDiscAU";

CREATE OR REPLACE VIEW public."vwUpdHybExpLoyFixedPctDiscAU"
 AS
 WITH base AS (
         SELECT eo."eventId" AS event_id,
            eo.page,
            eo."pagePosition",
            eo."offerId",
            ot."offerTypeId" AS offer_type_id,
            concat('C', 'AUS', 'E', eo."eventId", 'P', eo.page, 'P',
                CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"
                    ELSE eo."pagePosition"
                END, 'I', max(eo."commercialOfferItemClass1"::text), 'OT1LPR', 'P', round(eod."advertisedPriceGst"::numeric, 2)::numeric(19,2)::character varying(50), 'P', (floor(eod."calculatedSavePercentage" / 5::numeric) * 5::numeric)::integer, 'V', 1) AS "PROMOTION_CODE",
            ot."hybrisLoyaltyStickerBackgroundColor" AS "STICKER_BGCOLOR",
            ot."hybrisLoyaltyStickerTextColor" AS "STICKER_COLOR",
            ot."hybrisLoyaltyStickerText" AS "STICKER_TEXT",
            ot."hybrisLoyaltyPillBackgroundColor" AS "PILL_BGCOLOR",
            ot."hybrisLoyaltyPillTextColor" AS "PILL_COLOR",
                CASE
                    WHEN max(eod."calculatedSaveValue") <= 0::numeric THEN 'Catalogue Rewards Offer'::character varying
                    ELSE
                    CASE
                        WHEN (eo."hybrisPillText"::text = ANY (ARRAY['Catalogue Rewards Offer'::character varying::text, 'Catalogue Rewards Offer'::character varying::text])) OR "right"(eo."hybrisPillText"::text, 9) = 'Available'::text OR eo."hybrisPillText" IS NULL THEN ot."hybrisLoyaltyPillText"
                        ELSE eo."hybrisPillText"
                    END
                END AS "PILL_TEXT",
            ot."hybrisLoyaltyCartMessage" AS "CART_MESSAGE",
            'VIP'::text AS "PROMOTION_CLASS",
            "left"(ev."priceList"::text, 3) AS "PRICELIST_CODE",
            concat(to_char(ev."startDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."startTime") AS "START_DATE",
            concat(to_char(ev."endDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."endTime") AS "END_DATE",
                CASE
                    WHEN eod."fromPriceIndicator" = true AND (ot."offerTypeId" = 6 OR ot."offerTypeId" = 106) THEN floor(eod."advertisedPriceGst")::numeric(19,2)::character varying(50)
                    ELSE round(max(eod."advertisedPriceGst"), 2)::numeric(19,2)::character varying(50)
                END AS "VALUE",
            max(tc.configvalue ->> 'CURRTXT'::text) AS "CURRENCY",
            string_agg(DISTINCT eod.sku::text, ','::text ORDER BY (eod.sku::text)) AS "PRODUCTS",
            'False'::text AS "SHOW_PRICE_STRIKE_THROUGH",
            max(ev."salesKeyword"::text) AS "SALE_KEYWORDS"
           FROM "tEvent" ev
             JOIN "tEventOffer" eo ON ev."eventId" = eo."eventId"
             JOIN "tEventOfferDetail" eod ON eo."eventId" = eod."eventId" AND eo.page = eod.page AND eo."pagePosition" = eod."pagePosition" AND eo."offerId" = eod."offerId" AND eo."offerNumber" = eod."offerNo" and eod."isSkuActive"=true
             JOIN "tProducts" p ON eod.sku::text = p.sku::text
             JOIN "tOfferType" ot ON eo."commercialOfferType"::text = ot."offerType"::text AND ev.country::text = ot.country::text
             JOIN "tConfig" tc ON ev.country::text = tc.configkey::text AND tc.configtype::text = 'COUNTRY'::text
             LEFT JOIN "tHybrisStickerText" hst ON eo."hybrisStickerText"::text = hst."hybrisStickerText"::text AND ev.country::text = hst.country::text
          WHERE ev.country::text = 'AU'::text AND ev.locked = true AND eo."isNotAvailableOnline" = false AND eod."advertisedPrice" > 0::numeric AND ((ot."offerTypeId" = ANY (ARRAY[1, 101])) OR (ot."offerTypeId" = ANY (ARRAY[6, 106])) AND eod."fromPriceIndicator" = true) AND eo."isRewards" = true AND NOT (ev."eventType"::text = 'Retail Catalogue'::text AND eo."pagePosition" = 0)
          GROUP BY eo."eventId", eo.page, eo."pagePosition", eo."offerId", ot."offerTypeId", ((floor(eod."calculatedSavePercentage" / 5::numeric) * 5::numeric)::integer), (round(eod."advertisedPriceGst"::numeric, 2)::numeric(19,2)), ot."hybrisLoyaltyStickerBackgroundColor", ot."hybrisLoyaltyStickerTextColor", ot."hybrisLoyaltyStickerText", ot."hybrisLoyaltyPillBackgroundColor", ot."hybrisLoyaltyPillTextColor", ot."hybrisLoyaltyPillText", ot."hybrisLoyaltyCartMessage", eo."hybrisPillText", ev."priceList", ev."startDate", ev."endDate", ev."startTime", ev."endTime", eod."fromPriceIndicator", eod."advertisedPriceGst"
        UNION ALL
         SELECT eo."eventId" AS event_id,
            eo.page,
            eo."pagePosition",
            eo."offerId",
            ot."offerTypeId" AS offer_type_id,
            concat('C', 'AUS', 'E', eo."eventId", 'P', eo.page, 'P',
                CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"
                    ELSE eo."pagePosition"
                END, 'I', max(eo."commercialOfferItemClass1"::text), 'OT6PCT', 'P', (floor(eo."savePercent" / 5::numeric) * 5::numeric)::integer, 'V', 1) AS "PROMOTION_CODE",
            ot."hybrisLoyaltyStickerBackgroundColor" AS "STICKER_BGCOLOR",
            ot."hybrisLoyaltyStickerTextColor" AS "STICKER_COLOR",
            ot."hybrisLoyaltyStickerText" AS "STICKER_TEXT",
            ot."hybrisLoyaltyPillBackgroundColor" AS "PILL_BGCOLOR",
            ot."hybrisLoyaltyPillTextColor" AS "PILL_COLOR",
            'Catalogue Rewards Offer'::text AS "PILL_TEXT",
            ot."hybrisLoyaltyCartMessage" AS "CART_MESSAGE",
            'VIP'::text AS "PROMOTION_CLASS",
            "right"(ev."priceList"::text, 3) AS "PRICELIST_CODE",
            concat(to_char(ev."startDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."startTime") AS "START_DATE",
            concat(to_char(ev."endDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."endTime") AS "END_DATE",
            round(eo."savePercent", 2)::character varying(50) AS "VALUE",
            NULL::text AS "CURRENCY",
            string_agg(DISTINCT eod.sku::text, ','::text ORDER BY (eod.sku::text)) AS "PRODUCTS",
            'False'::text AS "SHOW_PRICE_STRIKE_THROUGH",
            max(ev."salesKeyword"::text) AS "SALE_KEYWORDS"
           FROM "tEvent" ev
             JOIN "tEventOffer" eo ON ev."eventId" = eo."eventId"
             JOIN "tEventOfferDetail" eod ON eo."eventId" = eod."eventId" AND eo.page = eod.page AND eo."pagePosition" = eod."pagePosition" AND eo."offerId" = eod."offerId" AND eo."offerNumber" = eod."offerNo" and eod."isSkuActive"=true
             JOIN "tProducts" p ON eod.sku::text = p.sku::text
             JOIN "tOfferType" ot ON eo."commercialOfferType"::text = ot."offerType"::text AND ev.country::text = ot.country::text
             LEFT JOIN "tHybrisStickerText" hst ON eo."hybrisStickerText"::text = hst."hybrisStickerText"::text AND ev.country::text = hst.country::text
          WHERE ev.country::text = 'AU'::text AND ev.locked = true AND eo."isNotAvailableOnline" = false AND eod."advertisedPrice" > 0::numeric AND (ot."offerTypeId" = ANY (ARRAY[6, 106])) AND COALESCE(eod."fromPriceIndicator", false) = false AND eo."isRewards" = true AND NOT (ev."eventType"::text = 'Retail Catalogue'::text AND eo."pagePosition" = 0)
          GROUP BY eo."eventId", eo.page, eo."pagePosition", eo."offerId", ot."offerTypeId", eo."savePercent", ot."hybrisLoyaltyStickerBackgroundColor", ot."hybrisLoyaltyStickerTextColor", ot."hybrisLoyaltyStickerText", ot."hybrisLoyaltyPillBackgroundColor", ot."hybrisLoyaltyPillTextColor", ot."hybrisLoyaltyCartMessage", ev."priceList", ev."startDate", ev."endDate", ev."startTime", ev."endTime"
        UNION ALL
         SELECT eo."eventId" AS event_id,
            eo.page,
            eo."pagePosition",
            eo."offerId",
            ot."offerTypeId" AS offer_type_id,
            concat('C', 'AUS', 'E', eo."eventId", 'P', eo.page, 'P',
                CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"
                    ELSE eo."pagePosition"
                END, 'I', max(eo."commercialOfferItemClass1"::text), 'OT', ot."offerTypeId"::text, 'PO', 'P', round(eod."advertisedPriceGst"::numeric, 2)::numeric(19,2)::character varying(50), 'V', 1) AS "PROMOTION_CODE",
            ot."hybrisLoyaltyStickerBackgroundColor" AS "STICKER_BGCOLOR",
            ot."hybrisLoyaltyStickerTextColor" AS "STICKER_COLOR",
            ot."hybrisLoyaltyStickerText" AS "STICKER_TEXT",
            ot."hybrisLoyaltyPillBackgroundColor" AS "PILL_BGCOLOR",
            ot."hybrisLoyaltyPillTextColor" AS "PILL_COLOR",
                CASE
                    WHEN (eo."hybrisPillText"::text = ANY (ARRAY['Catalogue Rewards Offer'::character varying::text, 'Catalogue Rewards Offer'::character varying::text])) OR "right"(eo."hybrisPillText"::text, 9) = 'Available'::text OR eo."hybrisPillText" IS NULL THEN ot."hybrisLoyaltyPillText"
                    ELSE eo."hybrisPillText"
                END AS "PILL_TEXT",
            ot."hybrisLoyaltyCartMessage" AS "CART_MESSAGE",
            'VIP'::text AS "PROMOTION_CLASS",
            "left"(ev."priceList"::text, 3) AS "PRICELIST_CODE",
            concat(to_char(ev."startDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."startTime") AS "START_DATE",
            concat(to_char(ev."endDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."endTime") AS "END_DATE",
            round(max(eod."advertisedPriceGst"), 2)::numeric(19,2)::character varying(50) AS "VALUE",
            max(tc.configvalue ->> 'CURRTXT'::text) AS "CURRENCY",
            string_agg(DISTINCT eod.sku::text, ','::text ORDER BY (eod.sku::text)) AS "PRODUCTS",
            'False'::text AS "SHOW_PRICE_STRIKE_THROUGH",
            max(ev."salesKeyword"::text) AS "SALE_KEYWORDS"
           FROM "tEvent" ev
             JOIN "tEventOffer" eo ON ev."eventId" = eo."eventId"
             JOIN "tEventOfferDetail" eod ON eo."eventId" = eod."eventId" AND eo.page = eod.page AND eo."pagePosition" = eod."pagePosition" AND eo."offerId" = eod."offerId" AND eo."offerNumber" = eod."offerNo" and eod."isSkuActive"=true
             JOIN "tProducts" p ON eod.sku::text = p.sku::text
             JOIN "tOfferType" ot ON eo."commercialOfferType"::text = ot."offerType"::text AND ev.country::text = ot.country::text
             JOIN "tConfig" tc ON ev.country::text = tc.configkey::text AND tc.configtype::text = 'COUNTRY'::text
             LEFT JOIN "tHybrisStickerText" hst ON eo."hybrisStickerText"::text = hst."hybrisStickerText"::text AND ev.country::text = hst.country::text
          WHERE ev.country::text = 'AU'::text AND ev.locked = true AND eo."isNotAvailableOnline" = false AND eod."advertisedPrice" > 0::numeric AND (ot."offerTypeId" = ANY (ARRAY[13, 23])) AND eo."isRewards" = true AND NOT (ev."eventType"::text = 'Retail Catalogue'::text AND eo."pagePosition" = 0)
          GROUP BY eo."eventId", eo.page, eo."pagePosition", eo."offerId", ot."offerTypeId", (round(eod."advertisedPriceGst"::numeric, 2)::numeric(19,2)), ot."hybrisLoyaltyStickerBackgroundColor", ot."hybrisLoyaltyStickerTextColor", ot."hybrisLoyaltyStickerText", ot."hybrisLoyaltyPillBackgroundColor", ot."hybrisLoyaltyPillTextColor", ot."hybrisLoyaltyPillText", ot."hybrisLoyaltyCartMessage", eo."hybrisPillText", ev."priceList", ev."startDate", ev."endDate", ev."startTime", ev."endTime"
        UNION ALL
         SELECT eo."eventId" AS event_id,
            eo.page,
            eo."pagePosition",
            eo."offerId",
            ot."offerTypeId" AS offer_type_id,
            concat('C', 'AUS', 'E', eo."eventId", 'P', eo.page, 'P',
                CASE
                    WHEN eo."pagePosition" = 0 THEN eo."offerId"
                    ELSE eo."pagePosition"
                END, 'I', max(eo."commercialOfferItemClass1"::text), 'OT14STDPR', 'S', 'V', 1) AS "PROMOTION_CODE",
            ot."hybrisLoyaltyStickerBackgroundColor" AS "STICKER_BGCOLOR",
            ot."hybrisLoyaltyStickerTextColor" AS "STICKER_COLOR",
            ot."hybrisLoyaltyStickerText" AS "STICKER_TEXT",
            ot."hybrisLoyaltyPillBackgroundColor" AS "PILL_BGCOLOR",
            ot."hybrisLoyaltyPillTextColor" AS "PILL_COLOR",
                CASE
                    WHEN (eo."hybrisPillText"::text = ANY (ARRAY['Catalogue Rewards Offer'::character varying::text, 'Catalogue Rewards Offer'::character varying::text])) OR "right"(eo."hybrisPillText"::text, 9) = 'Available'::text OR eo."hybrisPillText" IS NULL THEN ot."hybrisLoyaltyPillText"
                    ELSE eo."hybrisPillText"
                END AS "PILL_TEXT",
            ot."hybrisLoyaltyCartMessage" AS "CART_MESSAGE",
            'VIP'::text AS "PROMOTION_CLASS",
            "left"(ev."priceList"::text, 3) AS "PRICELIST_CODE",
            concat(to_char(ev."startDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."startTime") AS "START_DATE",
            concat(to_char(ev."endDate"::timestamp with time zone, 'DD-MM-YYYY'::text), ' ', ev."endTime") AS "END_DATE",
            round(max(eod."advertisedPriceGst"), 2)::numeric(19,2)::character varying(50) AS "VALUE",
            max(tc.configvalue ->> 'CURRTXT'::text) AS "CURRENCY",
            string_agg(DISTINCT eod.sku::text, ','::text ORDER BY (eod.sku::text)) AS "PRODUCTS",
            'False'::text AS "SHOW_PRICE_STRIKE_THROUGH",
            max(ev."salesKeyword"::text) AS "SALE_KEYWORDS"
           FROM "tEvent" ev
             JOIN "tEventOffer" eo ON ev."eventId" = eo."eventId"
             JOIN "tEventOfferDetail" eod ON eo."eventId" = eod."eventId" AND eo.page = eod.page AND eo."pagePosition" = eod."pagePosition" AND eo."offerId" = eod."offerId" AND eo."offerNumber" = eod."offerNo" and eod."isSkuActive"=true
             JOIN "tProducts" p ON eod.sku::text = p.sku::text
             JOIN "tOfferType" ot ON eo."commercialOfferType"::text = ot."offerType"::text AND ev.country::text = ot.country::text
             JOIN "tConfig" tc ON ev.country::text = tc.configkey::text AND tc.configtype::text = 'COUNTRY'::text
             LEFT JOIN "tHybrisStickerText" hst ON eo."hybrisStickerText"::text = hst."hybrisStickerText"::text AND ev.country::text = hst.country::text
          WHERE ev.country::text = 'AU'::text AND ev.locked = true AND eo."isNotAvailableOnline" = false AND eod."advertisedPrice" > 0::numeric AND ot."offerTypeId" = 14 AND eo."isRewards" = true AND NOT (ev."eventType"::text = 'Retail Catalogue'::text AND eo."pagePosition" = 0)
          GROUP BY eo."eventId", eo.page, eo."pagePosition", eo."offerId", ot."offerTypeId", ot."hybrisLoyaltyStickerBackgroundColor", ot."hybrisLoyaltyStickerTextColor", ot."hybrisLoyaltyStickerText", ot."hybrisLoyaltyPillBackgroundColor", ot."hybrisLoyaltyPillTextColor", ot."hybrisLoyaltyPillText", ot."hybrisLoyaltyCartMessage", eo."hybrisPillText", ev."priceList", ev."startDate", ev."endDate", ev."startTime", ev."endTime"
        ), promo_meta AS (
         SELECT base.event_id,
            base.page,
            base."pagePosition",
            base."offerId",
            base.offer_type_id,
            base."PROMOTION_CODE",
            max(base."STICKER_BGCOLOR"::text) AS "STICKER_BGCOLOR",
            max(base."STICKER_COLOR"::text) AS "STICKER_COLOR",
            max(base."STICKER_TEXT"::text) AS "STICKER_TEXT",
            max(base."PILL_BGCOLOR"::text) AS "PILL_BGCOLOR",
            max(base."PILL_COLOR"::text) AS "PILL_COLOR",
            max(base."PILL_TEXT"::text) AS "PILL_TEXT",
            max(base."CART_MESSAGE"::text) AS "CART_MESSAGE",
            max(base."PROMOTION_CLASS") AS "PROMOTION_CLASS",
            max(base."PRICELIST_CODE") AS "PRICELIST_CODE",
            max(base."START_DATE") AS "START_DATE",
            max(base."END_DATE") AS "END_DATE",
            max(base."VALUE"::text) AS "VALUE",
            max(base."CURRENCY") AS "CURRENCY",
            max(base."SHOW_PRICE_STRIKE_THROUGH") AS "SHOW_PRICE_STRIKE_THROUGH",
            max(base."SALE_KEYWORDS") AS "SALE_KEYWORDS"
           FROM base
          WHERE base.offer_type_id = ANY (ARRAY[6, 14, 23, 106])
          GROUP BY base.event_id, base.page, base."pagePosition", base."offerId", base.offer_type_id, base."PROMOTION_CODE"
        ), exploded AS (
         SELECT b.event_id,
            b.page,
            b."pagePosition",
            b."offerId",
            b.offer_type_id,
            b."PROMOTION_CODE",
            sku_single.sku_single
           FROM base b
             CROSS JOIN LATERAL unnest(string_to_array(b."PRODUCTS", ','::text)) sku_single(sku_single)
          WHERE b.offer_type_id = ANY (ARRAY[6, 14, 23, 106])
        ), exploded_rn AS (
         SELECT e.event_id,
            e.page,
            e."pagePosition",
            e."offerId",
            e.offer_type_id,
            e."PROMOTION_CODE",
            e.sku_single,
            row_number() OVER (PARTITION BY e.event_id, e.page, e."pagePosition", e."offerId", e.offer_type_id, e."PROMOTION_CODE" ORDER BY e.sku_single) AS rn
           FROM exploded e
        ), chunked AS (
         SELECT m.event_id,
            m.page,
            m."pagePosition",
            m."offerId",
            m.offer_type_id,
            m."PROMOTION_CODE",
            m."STICKER_BGCOLOR",
            m."STICKER_COLOR",
            m."STICKER_TEXT",
            m."PILL_BGCOLOR",
            m."PILL_COLOR",
            m."PILL_TEXT",
            m."CART_MESSAGE",
            m."PROMOTION_CLASS",
            m."PRICELIST_CODE",
            m."START_DATE",
            m."END_DATE",
            m."VALUE",
            m."CURRENCY",
            m."SHOW_PRICE_STRIKE_THROUGH",
            m."SALE_KEYWORDS",
            floor(((er.rn - 1) / 2000)::double precision)::integer AS chunk_index,
            string_agg(er.sku_single, ','::text ORDER BY er.sku_single) AS "PRODUCTS"
           FROM exploded_rn er
             JOIN promo_meta m ON m.event_id = er.event_id AND m.page = er.page AND m."pagePosition" = er."pagePosition" AND m."offerId" = er."offerId" AND m.offer_type_id = er.offer_type_id AND m."PROMOTION_CODE" = er."PROMOTION_CODE"
          GROUP BY m.event_id, m.page, m."pagePosition", m."offerId", m.offer_type_id, m."PROMOTION_CODE", m."STICKER_BGCOLOR", m."STICKER_COLOR", m."STICKER_TEXT", m."PILL_BGCOLOR", m."PILL_COLOR", m."PILL_TEXT", m."CART_MESSAGE", m."PROMOTION_CLASS", m."PRICELIST_CODE", m."START_DATE", m."END_DATE", m."VALUE", m."CURRENCY", m."SHOW_PRICE_STRIKE_THROUGH", m."SALE_KEYWORDS", (floor(((er.rn - 1) / 2000)::double precision))
        ), unchanged AS (
         SELECT base.event_id,
            base.page,
            base."pagePosition",
            base."offerId",
            base.offer_type_id,
            base."PROMOTION_CODE",
            base."STICKER_BGCOLOR",
            base."STICKER_COLOR",
            base."STICKER_TEXT",
            base."PILL_BGCOLOR",
            base."PILL_COLOR",
            base."PILL_TEXT",
            base."CART_MESSAGE",
            base."PROMOTION_CLASS",
            base."PRICELIST_CODE",
            base."START_DATE",
            base."END_DATE",
            base."VALUE",
            base."CURRENCY",
            base."PRODUCTS",
            base."SHOW_PRICE_STRIKE_THROUGH",
            base."SALE_KEYWORDS",
            NULL::integer AS chunk_index
           FROM base
          WHERE base.offer_type_id <> ALL (ARRAY[6, 14, 23, 106])
        ), final_rows AS (
         SELECT unchanged.event_id,
            unchanged.page,
            unchanged."pagePosition",
            unchanged."offerId",
            unchanged.offer_type_id,
            unchanged."PROMOTION_CODE",
            unchanged."STICKER_BGCOLOR",
            unchanged."STICKER_COLOR",
            unchanged."STICKER_TEXT",
            unchanged."PILL_BGCOLOR",
            unchanged."PILL_COLOR",
            unchanged."PILL_TEXT",
            unchanged."CART_MESSAGE",
            unchanged."PROMOTION_CLASS",
            unchanged."PRICELIST_CODE",
            unchanged."START_DATE",
            unchanged."END_DATE",
            unchanged."VALUE",
            unchanged."CURRENCY",
            unchanged."PRODUCTS",
            unchanged."SHOW_PRICE_STRIKE_THROUGH",
            unchanged."SALE_KEYWORDS",
            unchanged.chunk_index
           FROM unchanged
        UNION ALL
         SELECT chunked.event_id,
            chunked.page,
            chunked."pagePosition",
            chunked."offerId",
            chunked.offer_type_id,
            chunked."PROMOTION_CODE",
            chunked."STICKER_BGCOLOR",
            chunked."STICKER_COLOR",
            chunked."STICKER_TEXT",
            chunked."PILL_BGCOLOR",
            chunked."PILL_COLOR",
            chunked."PILL_TEXT",
            chunked."CART_MESSAGE",
            chunked."PROMOTION_CLASS",
            chunked."PRICELIST_CODE",
            chunked."START_DATE",
            chunked."END_DATE",
            chunked."VALUE",
            chunked."CURRENCY",
            chunked."PRODUCTS",
            chunked."SHOW_PRICE_STRIKE_THROUGH",
            chunked."SALE_KEYWORDS",
            chunked.chunk_index
           FROM chunked
        )
 SELECT
        CASE
            WHEN (offer_type_id = ANY (ARRAY[6, 14, 23, 106])) AND COALESCE(chunk_index, 0) > 0 THEN ("PROMOTION_CODE" || '.'::text) || chunk_index::text
            ELSE "PROMOTION_CODE"
        END AS "PROMOTION_CODE",
    "STICKER_BGCOLOR",
    "STICKER_COLOR",
    "STICKER_TEXT",
    "PILL_BGCOLOR",
    "PILL_COLOR",
    "PILL_TEXT",
    "CART_MESSAGE",
    "PROMOTION_CLASS",
    "PRICELIST_CODE",
    "START_DATE",
    "END_DATE",
    "VALUE",
    "CURRENCY",
    "PRODUCTS",
    "SHOW_PRICE_STRIKE_THROUGH",
    "SALE_KEYWORDS"
   FROM final_rows;



