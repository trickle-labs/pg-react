\set ON_ERROR_STOP on

CREATE SCHEMA conflict_fixture;
CREATE TYPE conflict_fixture.fact_row AS (patient_id bigint, diagnosis text);
CREATE TABLE conflict_fixture.source_a (patient_id bigint PRIMARY KEY, diagnosis text NOT NULL);
CREATE TABLE conflict_fixture.source_b (patient_id bigint PRIMARY KEY, diagnosis text NOT NULL);
CREATE VIEW conflict_fixture.derivation_a AS SELECT patient_id, diagnosis FROM conflict_fixture.source_a;
CREATE VIEW conflict_fixture.derivation_b AS SELECT patient_id, diagnosis FROM conflict_fixture.source_b;
CREATE TABLE conflict_fixture.identity (relation_version_id uuid PRIMARY KEY);

INSERT INTO conflict_fixture.identity
SELECT pgreact.create_derived_relation(
    'conflict_fixture.current_fact', 'conflict_fixture.fact_row'::regtype,
    ARRAY['patient_id'], 1);
SELECT pgreact.create_derivation_rule(
    'conflict_fixture.derivation_a', 'conflict_fixture.derivation_a'::regclass,
    ARRAY['patient_id'], relation_version_id, 1)
FROM conflict_fixture.identity;
SELECT pgreact.create_derivation_rule(
    'conflict_fixture.derivation_b', 'conflict_fixture.derivation_b'::regclass,
    ARRAY['patient_id'], relation_version_id, 1)
FROM conflict_fixture.identity;
INSERT INTO conflict_fixture.source_a VALUES (7, 'influenza');
INSERT INTO conflict_fixture.source_b VALUES (7, 'pneumonia');

