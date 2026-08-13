\set ON_ERROR_STOP on
INSERT INTO m15_lifecycle.retry_source VALUES (
    'coexist', '123e4567-e89b-12d3-a456-426614174024');
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
SELECT 'M15 managed/external coexistence setup passed';
