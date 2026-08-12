\set ON_ERROR_STOP on
SELECT pgreact.begin_deadline_refresh(12501);
SELECT pg_sleep(2);
SELECT pgreact.finish_deadline_refresh();
