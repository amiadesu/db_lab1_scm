-- Запуск: psql -d db_lab1_scm -f 00_installation.sql
\set ON_ERROR_STOP on
\i 01_schema.sql
\i 02_functions.sql
\i 03_triggers.sql
\i 04_views.sql
\i 05_procedures.sql
\i 06_indexes.sql
\i 07_seed.sql
