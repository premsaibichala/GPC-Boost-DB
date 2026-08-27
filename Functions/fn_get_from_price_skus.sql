-- FUNCTION: public.fn_get_from_price_skus(integer)

-- DROP FUNCTION IF EXISTS public.fn_get_from_price_skus(integer);

CREATE OR REPLACE FUNCTION public.fn_get_from_price_skus(
	p_offerid integer)
    RETURNS TABLE(skus text, advprice numeric) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
      DECLARE
          v_lowestPrice NUMERIC(19,5);
          v_hasCriteriaMet BOOLEAN;
          v_skuList TEXT;
      BEGIN
          -- Check if any products meet the criteria
          SELECT EXISTS (
              SELECT 1
              FROM "tEventOfferDetail" eod
              INNER JOIN "tEvent" ev ON eod."eventId" = ev."eventId"
              INNER JOIN "tProducts" p ON eod."sku" = p."sku"
              INNER JOIN "tInventory" inv ON inv."sku" = eod."sku"
                                         AND inv."company" = ev."company"
              WHERE eod."offerId" = p_offerId
			  AND eod."advertisedPriceGst" >= 1
                AND inv."onHand" > 0
                AND (p."clearance" IS NULL OR p."clearance" <> 'Y')
                AND p."isActive" = TRUE
          ) INTO v_hasCriteriaMet;

          -- Get the lowest price based on criteria
          SELECT COALESCE(
              (SELECT MIN(eod."advertisedPriceGst")
               FROM "tEventOfferDetail" eod
               INNER JOIN "tEvent" ev ON eod."eventId" = ev."eventId"
               INNER JOIN "tProducts" p ON eod."sku" = p."sku"
               INNER JOIN "tInventory" inv ON inv."sku" = eod."sku"
                                          AND inv."company" = ev."company"
               WHERE eod."offerId" = p_offerId
			   AND eod."advertisedPriceGst" >= 1
                 AND inv."onHand" > 0
                 AND (p."clearance" IS NULL OR p."clearance" <> 'Y')
                 AND p."isActive" = TRUE),
              (SELECT MIN(eod."advertisedPriceGst")
               FROM "tEventOfferDetail" eod
               WHERE eod."offerId" = p_offerId
			   AND eod."advertisedPriceGst" >= 1)
          ) INTO v_lowestPrice;

          -- Get comma-separated SKUs based on criteria
          IF v_hasCriteriaMet THEN
              SELECT STRING_AGG(eod."sku", ',')
              INTO v_skuList
              FROM "tEventOfferDetail" eod
              INNER JOIN "tEvent" ev ON eod."eventId" = ev."eventId"
              INNER JOIN "tProducts" p ON eod."sku" = p."sku"
              INNER JOIN "tInventory" inv ON inv."sku" = eod."sku"
                                         AND inv."company" = ev."company"
              WHERE eod."offerId" = p_offerId
                AND eod."advertisedPriceGst" = v_lowestPrice
				AND eod."advertisedPriceGst" >= 1
                AND inv."onHand" > 0
                AND (p."clearance" IS NULL OR p."clearance" <> 'Y')
                AND p."isActive" = TRUE;
          ELSE
              SELECT STRING_AGG(eod."sku", ',')
              INTO v_skuList
              FROM "tEventOfferDetail" eod
              WHERE eod."offerId" = p_offerId
                AND eod."advertisedPriceGst" = v_lowestPrice
				AND eod."advertisedPriceGst" >= 1;
          END IF;

          -- Return single row with two columns
          RETURN QUERY SELECT v_skuList, v_lowestPrice;
      END;

  
$BODY$;