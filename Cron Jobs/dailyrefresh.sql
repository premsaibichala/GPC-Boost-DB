 SELECT cron.schedule_in_database(
    'daily_refresh_jobcombomultibuybxgy',
    '00 19 * * *',
$$CALL sp_update_event_offer_detailscombomultibuybxgy();$$,
     'psql-aes-gap-pps-aa-boost-01'
);
 
 
 
 SELECT cron.schedule_in_database(
    'daily_refresh_jobcombomultibuypriceonlyskulist',
   '15 19 * * *',
$$CALL sp_update_event_offer_detailscombomultibuypriceonlyskulist();$$,
     'psql-aes-gap-pps-aa-boost-01'
);
 
 
 
 SELECT cron.schedule_in_database(
    'daily_refresh_joblppobxgx',
    '30 19 * * *',
$$CALL sp_update_event_offer_detailslppobxgx();$$,
     'psql-aes-gap-pps-aa-boost-01'
);
 
 
 
 
 
 SELECT cron.schedule_in_database(
    'daily_refresh_jobpctstd',
    '45 19 * * *',
$$CALL sp_update_event_offer_detailspctstd();$$,
     'psql-aes-gap-pps-aa-boost-01'
);
 