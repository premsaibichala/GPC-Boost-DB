SELECT cron.schedule_in_database(
      'truncate_temp_tables_aest',
      '30 15 * * *',
      $$TRUNCATE TABLE
              public."tPriceProfile_temp",
              public."tCatalogueSalesHeader_temp",
              public."tSalesY1_temp",
              public."tPriceProductRules_temp",
              public."tLocation_temp",
              public."tPriceList_temp",
              public."tItemClass_temp",
              public."tItemLoadings_temp",
              public."tSupplier_temp",
              public."tCatalogueSales_temp",
              public."tStockCover_temp",
              public."tSalesY2_temp",
              public."tNationalAverageCost_temp",
              public."tInventory_temp",
              public."tProducts_temp",
              public."tProductSupplierCost_temp",
              public."tIicePartDesc_temp",
              public."tVendorItemDetail_temp",
              public."tPriceListDetail_temp",
              public."tCompanyItem_temp"
          RESTART IDENTITY CASCADE;
 
          INSERT INTO execution_log(job_name, status, start_time)
    VALUES ('Truncate Temp Tables', 'SUCCESS',  NOW());
      $$,
       'psql-aes-gap-pps-aa-boost-01'
  );
 