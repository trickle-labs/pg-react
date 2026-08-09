\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_trickle;
CREATE EXTENSION IF NOT EXISTS pg_react;
CREATE SCHEMA m5_fixture;

SELECT format('CREATE SCHEMA %I', :'actual_schema') \gexec
SELECT format('CREATE TABLE %1$I.facts (id bigint PRIMARY KEY, value integer NOT NULL, enabled boolean NOT NULL DEFAULT true)', :'actual_schema') \gexec
SELECT format('CREATE TABLE %1$I.actions (label text NOT NULL, activation_id uuid NOT NULL, value integer NOT NULL)', :'actual_schema') \gexec
SELECT format('CREATE TABLE %1$I.outbox (idempotency_key text PRIMARY KEY, envelope jsonb NOT NULL)', :'actual_schema') \gexec
SELECT format('CREATE VIEW m5_fixture.facts AS SELECT * FROM %I.facts', :'actual_schema') \gexec
SELECT format('CREATE VIEW m5_fixture.actions AS SELECT * FROM %I.actions', :'actual_schema') \gexec
SELECT format('CREATE VIEW m5_fixture.outbox AS SELECT * FROM %I.outbox', :'actual_schema') \gexec
SELECT format('CREATE VIEW %1$I.base_v1 AS SELECT id FROM %1$I.facts WHERE enabled', :'actual_schema') \gexec
SELECT format('CREATE VIEW %1$I.command_v1 AS SELECT id, value FROM %1$I.facts WHERE enabled', :'actual_schema') \gexec
SELECT format('CREATE VIEW %1$I.command_v2 AS SELECT id, value FROM %1$I.facts WHERE enabled AND value >= 0', :'actual_schema') \gexec
SELECT format($ddl$
    CREATE FUNCTION %1$I.act_v1(context pgreact.activation_context, match %1$I.command_v1)
    RETURNS void LANGUAGE SQL AS $fn$
        INSERT INTO %1$I.actions VALUES ('V1', (context).activation_id, (match).value)
    $fn$
$ddl$, :'actual_schema') \gexec
SELECT format($ddl$
    CREATE FUNCTION %1$I.act_v2(context pgreact.activation_context, match %1$I.command_v2)
    RETURNS void LANGUAGE SQL AS $fn$
        INSERT INTO %1$I.actions VALUES ('V2', (context).activation_id, (match).value)
    $fn$
$ddl$, :'actual_schema') \gexec
SELECT format($ddl$
    CREATE FUNCTION %1$I.enqueue(context pgreact.activation_context, envelope jsonb)
    RETURNS void LANGUAGE SQL AS $fn$
        INSERT INTO %1$I.outbox VALUES ((context).idempotency_key, envelope)
    $fn$
$ddl$, :'actual_schema') \gexec

CREATE TABLE m5_fixture.manifests (
    version text PRIMARY KEY,
    definition jsonb NOT NULL,
    mappings jsonb NOT NULL
);

INSERT INTO m5_fixture.manifests VALUES (
    '1',
    jsonb_build_object(
        'format_version', 1,
        'pack', 'risk-pack',
        'version', '1',
        'owner', 'author',
        'rules', jsonb_build_array(
            jsonb_build_object(
                'name', 'risk-base',
                'definition', 'logical.base',
                'key', 'id',
                'kind', 'CONSTRAINT',
                'depends_on', jsonb_build_array()
            ),
            jsonb_build_object(
                'name', 'risk-command',
                'definition', 'logical.command',
                'key', 'id',
                'kind', 'COMMAND',
                'on_activate', 'logical.activate(pgreact.activation_context,logical.command)',
                'old_work_policy', 'DRAIN_OLD',
                'depends_on', jsonb_build_array('risk-base')
            ),
            jsonb_build_object(
                'name', 'risk-outbox',
                'definition', 'logical.command',
                'key', 'id',
                'kind', 'COMMAND',
                'outbox', jsonb_build_object(
                    'ACTIVATE', 'logical.enqueue(pgreact.activation_context,jsonb)'
                ),
                'depends_on', jsonb_build_array('risk-command')
            )
        ),
        'remove', jsonb_build_array()
    ),
    jsonb_build_object(
        'roles', jsonb_build_object('author', current_user),
        'objects', jsonb_build_object(
            'logical.base', format('%I.base_v1', :'actual_schema'),
            'logical.command', format('%I.command_v1', :'actual_schema'),
            'logical.activate(pgreact.activation_context,logical.command)',
                format('%1$I.act_v1(pgreact.activation_context,%1$I.command_v1)', :'actual_schema'),
            'logical.enqueue(pgreact.activation_context,jsonb)',
                format('%I.enqueue(pgreact.activation_context,jsonb)', :'actual_schema')
        )
    )
);

INSERT INTO m5_fixture.manifests
SELECT
    '2',
    jsonb_build_object(
        'format_version', 1,
        'pack', 'risk-pack',
        'version', '2',
        'owner', 'author',
        'rules', jsonb_build_array(
            jsonb_build_object(
                'name', 'risk-command',
                'definition', 'logical.command',
                'key', 'id',
                'kind', 'COMMAND',
                'on_activate', 'logical.activate(pgreact.activation_context,logical.command)',
                'old_work_policy', 'DRAIN_OLD',
                'depends_on', jsonb_build_array()
            ),
            jsonb_build_object(
                'name', 'risk-outbox',
                'definition', 'logical.command',
                'key', 'id',
                'kind', 'COMMAND',
                'outbox', jsonb_build_object(
                    'ACTIVATE', 'logical.enqueue(pgreact.activation_context,jsonb)'
                ),
                'old_work_policy', 'CANCEL_OLD',
                'depends_on', jsonb_build_array('risk-command')
            )
        ),
        'remove', jsonb_build_array(
            jsonb_build_object('name', 'risk-base', 'old_work_policy', 'CANCEL_OLD')
        )
    ),
    jsonb_build_object(
        'roles', jsonb_build_object('author', current_user),
        'objects', jsonb_build_object(
            'logical.command', format('%I.command_v2', :'actual_schema'),
            'logical.activate(pgreact.activation_context,logical.command)',
                format('%1$I.act_v2(pgreact.activation_context,%1$I.command_v2)', :'actual_schema'),
            'logical.enqueue(pgreact.activation_context,jsonb)',
                format('%I.enqueue(pgreact.activation_context,jsonb)', :'actual_schema')
        )
    );

INSERT INTO m5_fixture.manifests
SELECT requested.version,
       jsonb_set(source.definition, '{version}', to_jsonb(requested.next_version)),
       source.mappings
FROM m5_fixture.manifests AS source CROSS JOIN LATERAL (VALUES
    ('3', '3'), ('4', '4')
) AS requested(version, next_version)
WHERE source.version = '2';

UPDATE m5_fixture.manifests
SET definition = jsonb_set(definition, '{remove}', '[]'::jsonb)
WHERE version IN ('3', '4');
