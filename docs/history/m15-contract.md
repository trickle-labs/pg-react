# M15 contract — runtime and usability completion

M15 is extension `0.12.0` and public contract version `5`.

## Managed runtime

Preload `pg_react` after `pg_trickle` and set `pg_react.databases` to a
comma-separated database allow-list. PostgreSQL starts one combined coordinator
and worker per unique configured database, restarts it after failure, and stops
it with PostgreSQL. `pg_react.worker_role`, `poll_interval_ms`, `batch_size`, and
`max_pending_jobs` bound identity, polling, claims, and backpressure.

Each cycle checks extension and protocol compatibility, recovery state, backlog,
and public coordination before using the inherited protocol-2 lease and retry
contract. The bundled `pg-reactd` remains transition-only: either worker may
claim protocol-compatible work, but row locks and leases prevent dual ownership.
Drain external workers before changing versions; start managed workers only
after `ALTER EXTENSION` and `doctor` succeed.

`managed_status()` is the exact public process state. `doctor()` adds managed
configuration, attachment, heartbeat, compatibility, and readiness diagnostics.
No routine operation requires a private catalog or raw worker protocol.

## Typed semantic keys

The portable codec matrix is `bigint`, `uuid`, and `text COLLATE "C"`, ordered
tuples of one through four distinct columns, and no null components. Type tags,
network-order lengths, binary values, declared component order, and SHA-256
identity are stable codec v2. PostgreSQL typed equality is authoritative.
Domains, nondeterministic or non-C text collations, mutable types, unordered
maps, duplicate projected identities, and null components are rejected before
durable state changes.

Array overloads of `validate_rule`, `author_rule`, `author_deadline_rule`, and
`declare_derived_relation` accept ordered key columns. Scalar M13/M14 overloads
remain compatible. Public `status`, `matches`, and `explain(text,jsonb)` render
the declared typed key; internal bigint surrogates never enter normal output.

## Recovery and upgrade

Physical backup/restore preserves the PostgreSQL-managed runtime metadata,
typed identities, pending work, histories, and evidence. Logical dump/restore
recreates deterministic wrapper identities from public declarations. Upgrade is
`0.11.0 -> 0.12.0`; existing bigint rules and pending work remain byte-exact.
New codec and managed-worker metadata are additive until a typed declaration or
managed worker first runs.

General scheduling, arbitrary background processes, exactly-once effects,
automatic HA, arbitrary codecs, nullable keys, and new reasoning semantics are
outside M15.
