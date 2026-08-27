-- PROCEDURE: public.sp_update_offer_and_sku_details()
 
-- DROP PROCEDURE IF EXISTS public.sp_update_offer_and_sku_details();
 
CREATE OR REPLACE PROCEDURE public.sp_update_offer_and_sku_details(
	)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_start_time timestamptz;
    v_end_time   timestamptz;
    v_log_id     bigint;
    v_job_name   text := 'sp_update_offer_and_sku_details';
BEGIN
    -- Run in Australia/Sydney time
    SET LOCAL TIME ZONE 'Australia/Sydney';

    -- Start log
    v_start_time := clock_timestamp();

    INSERT INTO execution_log (job_name, status, start_time)
    VALUES (v_job_name, 'STARTED', v_start_time)
    RETURNING id INTO v_log_id;

    -------------------------------------------------------------------------
    -- Step 1: Deactivate products that are no longer eligible.
    -- A product is deactivated when:
    --   1. It does not exist in the required price lists for its country.
    --   2. It does not have a matching entry in Price Product Rules.
    -------------------------------------------------------------------------
	RAISE NOTICE 'Started updating tProducts (Deactivate) at: %', clock_timestamp();
    UPDATE "tProducts" p
    SET "isActive" = FALSE
    WHERE p."isActive" = TRUE
      AND NOT EXISTS (
            SELECT 1
            FROM "tPriceListDetail" pld
            WHERE p."sku" = pld."sku"
              AND p."country" = pld."country"
              AND (
                    (p."country" = 'AU' AND pld."priceList" IN ('390','419','824','343','446','241','036'))
                 OR (p."country" = 'NZ' AND pld."priceList" IN ('371','274','211','044','134','021','492'))
                 OR (pld."priceList" = '050')
              )
	     AND pld."isActive" = TRUE
      )
      AND NOT EXISTS (
            SELECT 1
            FROM "tPriceProductRules" ppr
            WHERE p."sku" = ppr."sku"
              AND p."country" = ppr."country"
	      AND ppr."isActive" = TRUE
      );
	RAISE NOTICE 'Finished updating tProducts (Deactivate) at: %', clock_timestamp();
 
    -------------------------------------------------------------------------
    -- Step 2: Reactivate products that satisfy both conditions:
    --   1. Available in the required price lists.
    --   2. Present in Price Product Rules.
    -------------------------------------------------------------------------
    RAISE NOTICE 'Started updating tProducts (Activate) at: %', clock_timestamp();
 
	UPDATE "tProducts" p
    SET "isActive" = TRUE
    WHERE p."isActive" = FALSE
      AND EXISTS (
            SELECT 1
            FROM "tPriceListDetail" pld
            WHERE p."sku" = pld."sku"
              AND p."country" = pld."country"
              AND (
                    (p."country" = 'AU' AND pld."priceList" IN ('390','419','824','343','446','241','036'))
                 OR (p."country" = 'NZ' AND pld."priceList" IN ('371','274','211','044','134','021','492'))
                 OR (pld."priceList" = '050')
              )
             AND pld."isActive" = TRUE
      );
       UPDATE "tProducts" p
    SET "isActive" = TRUE
    WHERE p."isActive" = FALSE
      AND EXISTS (
            SELECT 1
            FROM "tPriceProductRules" ppr
            WHERE p."sku" = ppr."sku"
              AND p."country" = ppr."country"
	      AND ppr."isActive" = TRUE
      );
 
	RAISE NOTICE 'Finished updating tProducts (Activate) at: %', clock_timestamp();
    -------------------------------------------------------------------------
    -- Step 3: Mark SKU records as inactive for products that have been
    -- deactivated.
    -------------------------------------------------------------------------
   RAISE NOTICE 'Started updating tEventOfferDetail (Deactivate SKUs) at: %', clock_timestamp();
   UPDATE "tEventOfferDetail" eod
    SET "isSkuActive" = FALSE
    FROM "tEvent" ev,
         "tProducts" p
    WHERE ev."eventId" = eod."eventId"
      AND p."sku" = eod."sku"
      AND p."isActive" = FALSE
      AND eod."isSkuActive" = TRUE;
	RAISE NOTICE 'Finished updating tEventOfferDetail (Deactivate SKUs) at: %', clock_timestamp();
    -------------------------------------------------------------------------
    -- Step 4: Reactivate SKU records whose products are active again.
    -------------------------------------------------------------------------
    RAISE NOTICE 'Started updating tEventOfferDetail (Activate SKUs) at: %', clock_timestamp();
	UPDATE "tEventOfferDetail" eod
    SET "isSkuActive" = TRUE
    FROM "tEvent" ev,
         "tProducts" p
    WHERE ev."eventId" = eod."eventId"
      AND p."sku" = eod."sku"
      AND p."isActive" = TRUE
      AND eod."isSkuActive" = FALSE;
 
	RAISE NOTICE 'Finished updating tEventOfferDetail (Activate SKUs) at: %', clock_timestamp();
    -------------------------------------------------------------------------
    -- Step 5: Deactivate offers for active events.
    --
    -- If any Offer Number within an offer has zero active SKUs,
    -- the entire offer is marked inactive and removed from the page.
    -------------------------------------------------------------------------
    RAISE NOTICE 'Started updating tEventOffer (Deactivate Offers) at: %', clock_timestamp();
	UPDATE "tEventOffer" eo
    SET "pagePosition" = 0,
        "isOfferActive" = FALSE
    FROM "tEvent" ev
    WHERE ev."eventId" = eo."eventId"
      AND ev."status" IN ('Open', 'Locked') 
      AND EXISTS (
            SELECT 1
            FROM "tEventOfferDetail" eod
            WHERE eod."offerId" = eo."offerId"
            GROUP BY eod."offerId", eod."offerNo"
            HAVING COUNT(*) FILTER (
                WHERE eod."isSkuActive" = TRUE
            ) = 0
      );
 
	 RAISE NOTICE 'Finished updating tEventOffer (Deactivate Offers) at: %', clock_timestamp();
    -------------------------------------------------------------------------
    -- Step 6: Reactivate offers when every Offer Number has at least
    -- one active SKU.
    -------------------------------------------------------------------------
   RAISE NOTICE 'Started updating tEventOffer (Activate Offers) at: %', clock_timestamp();
   UPDATE "tEventOffer" eo
    SET "isOfferActive" = TRUE
    FROM "tEvent" ev
    WHERE ev."eventId" = eo."eventId"
      AND ev."status" IN ('Open', 'Locked') 
      AND NOT EXISTS (
            SELECT 1
            FROM "tEventOfferDetail" eod
            WHERE eod."offerId" = eo."offerId"
            GROUP BY eod."offerId", eod."offerNo"
            HAVING COUNT(*) FILTER (
                WHERE eod."isSkuActive" = TRUE
            ) = 0
      );
 
	RAISE NOTICE 'Finished updating tEventOffer (Activate Offers) at: %', clock_timestamp();
    -------------------------------------------------------------------------
    -- Step 7: Reset search history positions for offers that have been
    -- deactivated.
    -------------------------------------------------------------------------
    RAISE NOTICE 'Started updating tEventOfferSearchHistory at: %', clock_timestamp();
	UPDATE "tEventOfferSearchHistory" esh
    SET "positionId" = 0
    FROM "tEventOffer" eo,
         "tEvent" ev
    WHERE esh."eventOfferId" = eo."offerId"
      AND ev."eventId" = eo."eventId"
      AND ev."status" IN ('Open', 'Locked') 
      AND eo."isOfferActive" = FALSE;
 
	RAISE NOTICE 'Finished updating tEventOfferSearchHistory at: %', clock_timestamp();
    -------------------------------------------------------------------------
    -- Step 8: Remove all mud map assignments and offer details for
    -- inactive offers, making the location available for reuse.
    -------------------------------------------------------------------------
    RAISE NOTICE 'Started updating tMudMapDetail at: %', clock_timestamp();
	UPDATE "tMudMapDetail" mmd
    SET
        "eventOfferId"     = NULL,
        "offerName"        = NULL,
        "offerType"        = NULL,
        "everydayPrice"    = NULL,
        "isReserved"       = FALSE,
        "advertisedPrice"  = NULL,
        "saveValue"        = NULL,
        "savePercent"      = NULL,
        "message"          = NULL,
        "partNumber"       = NULL,
        "clearance"        = NULL,
        "multiBuy"         = NULL,
        "combo"            = NULL,
        "new"              = NULL,
        "loyality"         = NULL,
        "isActive"         = FALSE,
        "userName"         = NULL,
        "requiredQuantity" = NULL,
        "fromPrice"        = NULL,
        "purchaseQuantity" = NULL,
        "freeQuantity"     = NULL,
        "lockedAt"         = NULL,
        "offerTypeId"      = NULL
    FROM "tEventOffer" eo,
         "tEvent" ev
    WHERE mmd."eventOfferId" = eo."offerId"
      AND ev."eventId" = eo."eventId"
      AND ev."status" IN ('Open', 'Locked') 
      AND eo."isOfferActive" = FALSE;
 
	RAISE NOTICE 'Finished updating tMudMapDetail at: %', clock_timestamp();
    -------------------------------------------------------------------------
    -- Step 9: Reset page positions of offer details belonging to
    -- inactive offers.
    -------------------------------------------------------------------------
    RAISE NOTICE 'Started updating tEventOfferDetail (Reset Page Position) at: %', clock_timestamp();
	UPDATE "tEventOfferDetail" eod
    SET "pagePosition" = 0
    FROM "tEventOffer" eo,
         "tEvent" ev
    WHERE eod."offerId" = eo."offerId"
      AND ev."eventId" = eo."eventId"
      AND ev."status" IN ('Open', 'Locked') 
      AND eo."isOfferActive" = FALSE;
 
	RAISE NOTICE 'Finished updating tEventOfferDetail (Reset Page Position) at: %', clock_timestamp();

    v_end_time := clock_timestamp();

    UPDATE execution_log
    SET status      = 'SUCCESS',
        end_time    = v_end_time,
        duration_ms = (EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000)::bigint
    WHERE id = v_log_id;

EXCEPTION
    WHEN OTHERS THEN
        v_end_time := clock_timestamp();

        RAISE LOG 'sp_update_offer_and_sku_details_Failed';

        UPDATE execution_log
        SET status      = 'FAILED',
            end_time    = v_end_time,
            duration_ms = (EXTRACT(EPOCH FROM (v_end_time - v_start_time)) * 1000)::bigint
        WHERE id = v_log_id;

        RAISE;

END;
$BODY$;