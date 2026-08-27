SELECT cron.schedule_in_database(
    'update_event_status',        
    '0 14 * * *',                        
    $$ SELECT * FROM public.run_event_status_update();$$,
     'psql-aes-gap-pps-aa-boost-01');
