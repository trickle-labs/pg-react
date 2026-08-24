# pg-react 0.5.0 — monotone recursive derivation

Version `0.5.0` adds bounded positive derivation chains and cycles with one
durable grounded least fixed point. Existing rule, worker, batch, pack, and
non-recursive derivation behavior remains unchanged.

## What changed since 0.4.0

- Format-version `1` rule packs can atomically add, replace, and remove
  versioned derivation programs.
- Exact nested dependencies are validated as a key-preserving positive subset;
  unsupported and non-monotone programs fail before mutation.
- Detected deltas trigger a bounded rebuild from empty under the component lock,
  so only one complete converged frontier becomes visible.
- Public program, component, run, iteration, support-input, explanation, and
  repair state expose convergence, failures, and grounded provenance without
  private catalogs.
- Stable input edges produce finite explanations with cycle markers, while
  ungrounded cycles retract after their last authoritative seed disappears.

## Upgrade from 0.4.0

The only supported in-place path is `0.4.0 -> 0.5.0`. There is no downgrade;
rollback requires restoring the tested pre-upgrade physical backup.

1. Stop workers and coordinators and take a tested physical backup.
2. Install the `0.5.0` shared library, control, install, and upgrade SQL files.
3. Run `ALTER EXTENSION pg_react UPDATE TO '0.5.0';`.
4. Reapply explicit grants, run recovery and health checks, then run
   `bash tests/m8.sh ghcr.io/trickle-labs/pg-react:v0.5.0` before resuming.

The migration preserves rules, packs, activations, lifecycle events, agenda
work, attempts, batches, derived relations, facts, supports, provenance, and
both worker protocols. New derivation-program catalogs start empty.

## Artifact publication

A complete release publishes the immutable tagged `linux/amd64` OCI image,
`pg-react-v0.5.0-linux-amd64.tar.gz`, its SHA-256 manifest, the OCI digest,
these notes, and the full M8 gate result.

## Known limitations

- Support remains PostgreSQL 18.3, pg_trickle 0.81.0, pgrx 0.18.0, Linux
  `amd64`, `READ COMMITTED`, coordinator-owned `DIFFERENTIAL`, non-null
  `bigint` keys, physical recovery, and no RLS source views.
- M8 rebuilds an affected program from empty and is bounded by declared
  `max_iterations` and `max_facts`; it is not a general recursive SQL engine.
- Negation, aggregation, outer and anti joins, `UNION`, temporal semantics,
  proof enumeration, confidence scores, and general tuple lineage are absent.
- Programs are deployed through rule packs. New execution modes and support
  matrix expansion are not included.
