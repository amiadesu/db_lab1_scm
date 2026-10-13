-- Запуск: psql -d supply_chain -f 00_install_all.sql
\set ON_ERROR_STOP on
\i 01_schema.sql
\i 02_functions.sql
\i 03_triggers.sql
\i 04_views.sql
\i 05_procedures.sql
\i 06_indexes.sql
\i 07_seed.sql
