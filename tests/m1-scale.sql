\set ON_ERROR_STOP on

CREATE SCHEMA m1_scale;
CREATE TABLE m1_scale.facts (id bigint PRIMARY KEY, payload text NOT NULL, enabled boolean NOT NULL, burst boolean NOT NULL);
INSERT INTO m1_scale.facts
SELECT value, repeat('x', 128), true, false FROM generate_series(1, 1000) AS value;
CREATE VIEW m1_scale.all_facts AS SELECT id, payload FROM m1_scale.facts WHERE enabled;
CREATE VIEW m1_scale.burst_facts AS SELECT id, payload FROM m1_scale.facts WHERE burst;
CREATE FUNCTION m1_scale.activate(context pgreact.activation_context, match m1_scale.burst_facts)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN NULL; END $$;

SELECT pgreact.create_rule('m1-scale-many-matches', 'm1_scale.all_facts'::regclass, ARRAY['id'], 'CONSTRAINT') AS many_matches_version_id \gset
SELECT count(*) = 1000 AS many_matches FROM pgreact.current_matches('m1-scale-many-matches') \gset
\if :many_matches
\else
  \quit 1
\endif
SELECT pgreact.create_rule('m1-scale-burst', 'm1_scale.burst_facts'::regclass, ARRAY['id'],
    on_activate => 'm1_scale.activate(pgreact.activation_context,m1_scale.burst_facts)'::regprocedure,
    bootstrap_policy => 'REQUIRE_EMPTY') AS burst_version_id \gset
UPDATE m1_scale.facts SET burst = true WHERE id <= 100;
SELECT pgreact.begin_refresh(:'burst_version_id'::uuid, 20001);
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT pgreact.refresh_rule(:'burst_version_id'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'burst_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT count(*) = 100 AS activation_burst FROM pgreact.episodes WHERE rule_version_id = :'burst_version_id'::uuid \gset
\if :activation_burst
\else
  \quit 1
\endif

SELECT pgreact.begin_refresh(:'burst_version_id'::uuid, 20002);
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT pgreact.refresh_rule(:'burst_version_id'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'burst_version_id'::uuid);
SELECT pgreact.release_refresh_lock();

DO $$
DECLARE version_id uuid; item integer;
BEGIN
  FOR item IN 1..16 LOOP
    EXECUTE format('CREATE VIEW m1_scale.few_%s AS SELECT id, payload FROM m1_scale.facts WHERE id = %s', item, item);
    SELECT pgreact.create_rule(format('m1-scale-few-%s', item), to_regclass(format('m1_scale.few_%s', item)), ARRAY['id'], 'CONSTRAINT') INTO version_id;
  END LOOP;
  FOR item IN 1..3 LOOP
    SELECT rule_version_id INTO version_id FROM pgreact.rules WHERE rule_name = 'm1-scale-few-1';
    PERFORM pgreact.pause_rule(version_id);
    PERFORM pgreact.replace_rule(version_id, 'm1_scale.few_1'::regclass, ARRAY['id'], NULL, 'SEED_CURRENT');
  END LOOP;
END
$$;

SELECT count(*) = 16 AS many_rules FROM pgreact.rules WHERE rule_name LIKE 'm1-scale-few-%' \gset
\if :many_rules
\else
  \quit 1
\endif
SELECT sum(octet_length(new_bindings::text)) >= 12800 AS payload_growth
FROM pgreact_internal.agenda WHERE rule_version_id = :'burst_version_id'::uuid \gset
\if :payload_growth
\else
  \quit 1
\endif

SELECT 'M1 scale smoke checks passed' AS result;
