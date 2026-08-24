# pg-react 0.6.0 — stratified negation

Version `0.6.0` adds safe keyed absence checks to bounded derivation programs.
Existing rule, worker, batch, pack, non-recursive, and positive-recursive
behavior remains unchanged.

## What changed since 0.5.0

- Rule-pack programs may declare range-restricted `negative_inputs` over
  authoritative or strictly lower-stratum derived relations.
- Public dependency-graph, stratum, frontier, and negative-evidence views expose
  the complete committed program state.
- Lower-stratum insertion retracts blocked higher support; removal restores it
  at one atomic program frontier.
- Explanations include satisfied negative checks without representing absence
  as a fact, and reconciliation repairs graph, evidence, support, and frontier
  drift.

## Upgrade from 0.5.0

Follow `docs/m9-upgrade.md`. The only supported in-place path is
`0.5.0 -> 0.6.0`; restore the tested physical backup instead of downgrading.

## Artifact publication

A complete release publishes the immutable tagged `linux/amd64` OCI image,
`pg-react-v0.6.0-linux-amd64.tar.gz`, its SHA-256 manifest, the OCI digest,
these notes, and the full M9 gate result.

## Known limitations

- The support matrix remains PostgreSQL 18.3, pg_trickle 0.81.0, pgrx 0.18.0,
  Linux `amd64`, `READ COMMITTED`, coordinator-owned `DIFFERENTIAL`, non-null
  `bigint` keys, physical recovery, and no RLS source views.
- Negation is keyed `NOT EXISTS` only. Negative cycles, aggregation, general
  antijoins, outer joins, `EXCEPT`, temporal absence, and open-world reasoning
  are unsupported.
