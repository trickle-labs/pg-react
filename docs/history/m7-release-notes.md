# pg-react 0.4.0 — maintained derived knowledge

Version `0.4.0` adds durable, non-recursive derived facts with exact logical supports, retraction, provenance, reconciliation, and rule-pack lifecycle management. Both existing worker protocols and ordinary rule behavior remain unchanged.

## What changed since 0.3.0

- Versioned typed derived relations expose read-only current-fact views.
- Consequence-free derivation rules maintain one immutable support per active match and never create agenda work.
- Multiple supports collapse to one fact; last-support removal retracts it; conflicting payloads roll back atomically.
- `current_facts`, `support_history`, `explain_fact`, repair diagnostics, and `health_check` expose current truth and recovery state.
- Format-version `1` rule packs can atomically add, replace, and explicitly remove derived relations, producers, and downstream consumers.

## Upgrade from 0.3.0

The only supported in-place path is `0.3.0 -> 0.4.0`. There is no downgrade; rollback requires restoring the tested pre-upgrade physical backup.

1. Stop workers and coordinators and take a tested physical backup.
2. Install the `0.4.0` control, install, and upgrade SQL files.
3. Run `ALTER EXTENSION pg_react UPDATE TO '0.4.0';`.
4. Reapply explicit role grants, run recovery and health checks, then run `bash tests/m7.sh ghcr.io/trickle-labs/pg-react:v0.4.0` before resuming workers.

The migration preserves rules, packs, activations, lifecycle events, agenda work, attempts, batches, and both worker protocols. New derived catalogs start empty.

## Artifact publication

A complete release publishes the immutable tagged `linux/amd64` OCI image, `pg-react-v0.4.0-linux-amd64.tar.gz`, its SHA-256 manifest, the OCI digest, these notes, and the full M7 gate result.

## Known limitations

- Support remains PostgreSQL 18.3, pg_trickle 0.81.0, pgrx 0.18.0, Linux `amd64`, `READ COMMITTED`, explicit coordinator-owned `DIFFERENTIAL` refresh, and no RLS source views.
- Keys remain one non-null unique `bigint`; physical backup/PITR is supported, but logical restoration of live runtime state is not.
- Derivations cannot read derived relations. Recursion, derivation chains, negation, temporal semantics, confidence scores, and general tuple lineage are not included.
- Downstream ordinary rules observe a changed derived frontier when refreshed in the next SQL statement.
