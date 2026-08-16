\set ON_ERROR_STOP on
CREATE SCHEMA m28_upgrade;
CREATE TABLE m28_upgrade.state (name text PRIMARY KEY, value text NOT NULL);
INSERT INTO m28_upgrade.state VALUES ('before', 'preserved');
