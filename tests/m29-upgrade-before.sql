\set ON_ERROR_STOP on
CREATE SCHEMA m29_upgrade;
CREATE TABLE m29_upgrade.state (name text PRIMARY KEY, value text NOT NULL);
INSERT INTO m29_upgrade.state VALUES ('before', 'preserved');
