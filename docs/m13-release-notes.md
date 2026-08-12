# pg-react 0.10.0 — core PostgreSQL ergonomics

Version `0.10.0` completes the ordinary PostgreSQL workflow. Authors use short
named `author_rule` calls, explicitly name the action schema, and may omit
`activation_context`. Resolution selects and records one exact authorized typed
function and rejects unsafe or ambiguous candidates before mutation.

Operators use one `run` call for sources, derived relations, programs,
downstream rules, deadlines, lifecycle state, and durable jobs. Concurrent runs
serialize through commit, repetition is idempotent, and failure rolls back the
complete coordinated state. Actions remain asynchronous and at least once.

`status`, `explain`, `matches`, `jobs`, and `attempts` provide application
language while exact historical engine evidence remains available. Deployment
configures distinct author, operator, worker, and reader roles with exact
function grants; `PUBLIC` and private schemas remain inaccessible.

The supported migration is `0.9.0 -> 0.10.0`. It preserves all M12 durable
state and repairs supplied stale facade grants. The PostgreSQL 18.3,
pg_trickle 0.81.0, pgrx 0.18.0, Linux `amd64`, `READ COMMITTED`, bigint-v1,
no-RLS, physical-recovery, worker-protocol-1/2, resource, and at-least-once
boundaries are unchanged.
