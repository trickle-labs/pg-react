\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE SCHEMA m26_upgrade;
CREATE TABLE m26_upgrade.candidates (
    subject bigint NOT NULL,
    candidate bigint NOT NULL,
    priority bigint NOT NULL,
    result text NOT NULL,
    PRIMARY KEY (subject, candidate)
);
INSERT INTO m26_upgrade.candidates VALUES (77, 7701, 1, 'preserved');
