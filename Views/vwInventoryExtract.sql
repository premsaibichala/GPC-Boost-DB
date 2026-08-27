-- View: public."vwInventoryExtract"

-- DROP VIEW public."vwInventoryExtract";

CREATE OR REPLACE VIEW public."vwInventoryExtract" AS
 WITH base AS (
         SELECT eo."eventId" AS "EVENTID",
            eod.page AS "PAGE",
                CASE
                    WHEN eod."pagePosition" = 0 THEN eod."offerId"
                    ELSE eod."pagePosition"
                END AS "PAGEPOSN",
            eo."offerId" AS "OFFERID",
            eo."commercialCategoryManager" AS "COMCATMAN",
            eod."comOfferCategory1" AS "COMOFFERIC1",
                CASE
                    WHEN eo."isRewards" = true THEN concat(eo."commercialOfferType", '-Loyal')::character varying(30)
                    ELSE eo."commercialOfferType"
                END AS "COMOFFERTYPE",
                CASE
                    WHEN eo."isRewards" = true THEN concat(eo."offerType", '-Loyal')::character varying(30)
                    ELSE eo."offerType"
                END AS "OFFERTYPE",
                CASE
                    WHEN eo."isRewards" = true THEN ot."offerTypeId" + 100
                    ELSE ot."offerTypeId"
                END AS "OFFERTYPEID",
            eo."offerNumber" AS "OFFERNO",
            p."partNo" AS "PARTNO",
            eod.sku AS "SKU",
            p.description AS "DESC",
            round(eod."nationalAverageCost", 2) AS "NATAVGCOST",
            round(eod."LatestEffectiveCost", 2) AS "LECOST",
                CASE
                    WHEN eo."categoryCostType"::text = 'ON PURCHASE'::text THEN round(eod."categoryCost", 2)
                    ELSE 0::numeric
                END AS "CATCOST",
                CASE
                    WHEN eo."OfferTypeId" = ANY (ARRAY[1, 4, 13, 17, 5]) THEN eo."purchaseQuantity"::integer
                    ELSE eod."purchaseQuantity"
                END AS "PURCHQTY",
            round(eod.categoryforecast::numeric, 2) AS "CATFCST",
            round(eod."incrementalForecast"::numeric, 2) AS "INCRFCST",
            false AS "FLWAEXCL",
            eo."copyReference" AS "COPYREF",
            round(eod."advertisedPriceGst", 2) AS "ADVPRICEGST",
                CASE
                    WHEN COALESCE(eod."group0Quantity", 0) > 0 OR COALESCE(eod."group1Quantity", 0) > 0 OR COALESCE(eod."group2Quantity", 0) > 0 OR COALESCE(eod."group3Quantity", 0) > 0 OR COALESCE(eod."group4Quantity", 0) > 0 OR COALESCE(eod."group5Quantity", 0) > 0 THEN 'Location'::text
                    ELSE NULL::text
                END AS "TIEUP",
                CASE
                    WHEN eod."group0Quantity" > 0 THEN eod."group0Quantity"
                    ELSE NULL::integer
                END AS "G0",
                CASE
                    WHEN eod."group1Quantity" > 0 THEN eod."group1Quantity"
                    ELSE NULL::integer
                END AS "G1",
                CASE
                    WHEN eod."group2Quantity" > 0 THEN eod."group2Quantity"
                    ELSE NULL::integer
                END AS "G2",
                CASE
                    WHEN eod."group3Quantity" > 0 THEN eod."group3Quantity"
                    ELSE NULL::integer
                END AS "G3",
                CASE
                    WHEN eod."group4Quantity" > 0 THEN eod."group4Quantity"
                    ELSE NULL::integer
                END AS "G4",
            NULL::text AS "M-G0",
            NULL::text AS "M-G1",
            NULL::text AS "M-G2",
            NULL::text AS "M-G3",
            NULL::text AS "M-G4",
            eod."fromPriceIndicator" AS "FROMPRCIND",
            'NO'::text AS "PRCONLY",
            eo.country AS "COUNTRY",
                CASE
                    WHEN eo."OfferTypeId" = ANY (ARRAY[25, 23, 15, 6, 14]) THEN 1
                    ELSE 0
                END AS apply_rules,
                CASE
                    WHEN (eo."OfferTypeId" = ANY (ARRAY[25, 23, 15, 6, 14])) AND (COALESCE(eod."group0Quantity", 0) > 0 OR COALESCE(eod."group1Quantity", 0) > 0 OR COALESCE(eod."group2Quantity", 0) > 0 OR COALESCE(eod."group3Quantity", 0) > 0 OR COALESCE(eod."group4Quantity", 0) > 0 OR COALESCE(eod."group5Quantity", 0) > 0) THEN 1
                    ELSE 0
                END AS is_tieup,
            eod."incrementalForecast"::numeric AS incr_fcst_guess
           FROM "tEventOffer" eo
             JOIN "tEvent" e ON eo."eventId" = e."eventId"
             JOIN "tEventOfferDetail" eod ON eo."eventId" = eod."eventId" AND eo.page = eod.page AND eo."pagePosition" = eod."pagePosition" AND eo."offerId" = eod."offerId" AND eo."offerNumber" = eod."offerNo"
             JOIN "tProducts" p ON eod.sku::text = p.sku::text
             JOIN "tOfferType" ot ON upper(eo."commercialOfferType"::text) = upper(ot."offerType"::text) AND e.country::text = ot.country::text
             LEFT JOIN "tEventPage" ep ON eo."eventId" = ep."eventId" AND eo.page = ep.page
          WHERE ep."pageDescription" IS NULL OR ep."pageDescription"::text <> 'Tie Up'::text AND NOT (e."eventType"::text = 'Retail Catalogue'::text AND eo."pagePosition" = 0 AND (ep."pageDescription"::text <> ALL (ARRAY['Front Page'::character varying::text, 'Back Page'::character varying::text])))
          AND ((e."status" IN ('Open', 'Locked') AND eo."isOfferActive" = TRUE AND eod."isSkuActive" = TRUE) OR (e."status" IN ('Completed', 'Cancelled')))
        ), ranked AS (
         SELECT b."EVENTID",
            b."PAGE",
            b."PAGEPOSN",
            b."OFFERID",
            b."COMCATMAN",
            b."COMOFFERIC1",
            b."COMOFFERTYPE",
            b."OFFERTYPE",
            b."OFFERTYPEID",
            b."OFFERNO",
            b."PARTNO",
            b."SKU",
            b."DESC",
            b."NATAVGCOST",
            b."LECOST",
            b."CATCOST",
            b."PURCHQTY",
            b."CATFCST",
            b."FLWAEXCL",
            b."COPYREF",
            b."ADVPRICEGST",
            b."TIEUP",
            b."G0",
            b."G1",
            b."G2",
            b."G3",
            b."G4",
            b."M-G0",
            b."M-G1",
            b."M-G2",
            b."M-G3",
            b."M-G4",
            b."FROMPRCIND",
            b."PRCONLY",
            b."COUNTRY",
            b.apply_rules,
            b.is_tieup,
            b.incr_fcst_guess,
            b."INCRFCST",
            COALESCE(b.incr_fcst_guess, 0::numeric) + COALESCE(b."CATFCST", 0::numeric) AS combined_score,
            count(*) FILTER (WHERE b.is_tieup = 1) OVER (PARTITION BY b."EVENTID", b."PAGE", b."PAGEPOSN", b."OFFERID", b."OFFERNO") AS tieup_count,
                CASE
                    WHEN b.is_tieup = 0 THEN row_number() OVER (PARTITION BY b."EVENTID", b."PAGE", b."PAGEPOSN", b."OFFERID", b."OFFERNO" ORDER BY (COALESCE(b.incr_fcst_guess, 0::numeric) + COALESCE(b."CATFCST", 0::numeric)) DESC)
                    ELSE NULL::bigint
                END AS rn_non_tie
           FROM base b
        )
 SELECT "EVENTID",
    "PAGE",
    "PAGEPOSN",
    "COMCATMAN",
    "COMOFFERIC1",
    "COMOFFERTYPE",
    "OFFERTYPE",
    "OFFERTYPEID",
    "OFFERNO",
    "PARTNO",
    "SKU",
    "DESC",
    "NATAVGCOST",
    "LECOST",
    "CATCOST",
    "PURCHQTY",
    "CATFCST",
    "FLWAEXCL",
    "COPYREF",
    "ADVPRICEGST",
    "TIEUP",
    "G0",
    "G1",
    "G2",
    "G3",
    "G4",
    "M-G0",
    "M-G1",
    "M-G2",
    "M-G3",
    "M-G4",
    "FROMPRCIND",
    "PRCONLY",
    "COUNTRY",
    "INCRFCST"
   FROM ( SELECT r."EVENTID",
            r."PAGE",
            r."PAGEPOSN",
            r."COMCATMAN",
            r."COMOFFERIC1",
            r."COMOFFERTYPE",
            r."OFFERTYPE",
            r."OFFERTYPEID",
            r."OFFERNO",
            r."PARTNO",
            r."SKU",
            r."DESC",
            r."NATAVGCOST",
            r."LECOST",
            r."CATCOST",
            r."PURCHQTY",
            r."CATFCST",
            r."FLWAEXCL",
            r."COPYREF",
            r."ADVPRICEGST",
            r."TIEUP",
            r."G0",
            r."G1",
            r."G2",
            r."G3",
            r."G4",
            r."M-G0",
            r."M-G1",
            r."M-G2",
            r."M-G3",
            r."M-G4",
            r."FROMPRCIND",
            r."PRCONLY",
            r."COUNTRY",
            r.apply_rules,
            r.is_tieup,
            r.incr_fcst_guess,
            r.combined_score,
            r.tieup_count,
            r.rn_non_tie,
            r."INCRFCST",
                CASE
                    WHEN r."PURCHQTY" IS NOT NULL AND r."PURCHQTY" > 0 THEN 1
                    WHEN r.apply_rules = 0 THEN 1
                    WHEN r.apply_rules = 1 AND r.is_tieup = 1 THEN 1
                    WHEN r.apply_rules = 1 AND r.is_tieup = 0 AND r.rn_non_tie IS NOT NULL AND r.rn_non_tie <= GREATEST(0::bigint, 5 - r.tieup_count) THEN 1
                    ELSE 0
                END AS include_flag
           FROM ranked r) t
  WHERE include_flag = 1
  ORDER BY "PAGE", "PAGEPOSN", "COMCATMAN", "COMOFFERIC1", "COMOFFERTYPE", "OFFERTYPE", "PARTNO";


