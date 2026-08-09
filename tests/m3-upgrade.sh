#!/usr/bin/env bash
set -euo pipefail

# Build an actual M2 database from the committed M2 install script, then apply
# the packaged 0.1.0 -> 0.1.1 migration. The package file lives only in this
# disposable container and is restored before the test exits.
compose=(docker compose)
git show dbfeefc:sql/pg_react--0.1.0.sql | "${compose[@]}" exec -T postgres sh -c \
  'tee /usr/share/postgresql/18/extension/pg_react--0.1.0.sql >/dev/null'
"${compose[@]}" exec -T postgres createdb -U postgres m3_upgrade
"${compose[@]}" exec -T postgres psql -X -U postgres -d m3_upgrade -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react VERSION '0.1.0';
CREATE SCHEMA app;
CREATE TABLE app.facts (id bigint PRIMARY KEY);
CREATE VIEW app.active_fact AS SELECT id FROM app.facts;
CREATE FUNCTION app.activate(context pgreact.activation_context, match app.active_fact)
RETURNS void LANGUAGE plpgsql AS 'BEGIN NULL; END';
SELECT pgreact.create_rule('upgrade-rule', 'app.active_fact'::regclass, ARRAY['id'], 'COMMAND',
    'app.activate(pgreact.activation_context,app.active_fact)'::regprocedure);
ALTER EXTENSION pg_react UPDATE TO '0.1.1';
SQL
"${compose[@]}" exec -T postgres psql -X -U postgres -d m3_upgrade -Atc \
  "SELECT extversion = '0.1.1' AND pgreact.worker_protocol_compatible(1) FROM pg_extension WHERE extname = 'pg_react'" | grep -qx t
"${compose[@]}" cp sql/pg_react--0.1.0.sql postgres:/usr/share/postgresql/18/extension/pg_react--0.1.0.sql >/dev/null
