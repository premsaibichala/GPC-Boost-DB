SELECT cron.schedule_in_database(
    'refresh_mvw_eventofferdetails_au',        
    '0 9 * * *',                        
    $$REFRESH MATERIALIZED VIEW mvw_eventofferdetails_au;$$,
     'psql-aes-gap-pps-aa-boost-01');
 
 
 
SELECT cron.schedule_in_database(
    'refresh_mvw_eventofferdetails_nz',
    '0 9 * * *',                          
    $$REFRESH MATERIALIZED VIEW mvw_eventofferdetails_nz;$$,
    'psql-aes-gap-pps-aa-boost-01'
);