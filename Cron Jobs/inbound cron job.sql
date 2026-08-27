 SELECT cron.schedule_in_database(
    'sequential_sp_cron_aest',
    '0 18 * * *',
    $$CALL public.run_inbound_cron();$$,
     'psql-aes-gap-pps-aa-boost-01'
);


SELECT cron.schedule_in_database(
    'sequential_sp_cron_aest_rerun',
    '0 20 * * *',
    $$CALL public.run_inbound_cron();$$,
     'psql-aes-gap-pps-aa-boost-01'
);