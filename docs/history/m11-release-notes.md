# pg-react 0.8.0 — `pgreact_api` facade

Version `0.8.0` begins M11 with `pgreact_api`, the supported PostgreSQL-facing
facade for the replacement API. It separates the new public contract from the
provisional `pgreact` names used by `0.7.0`.

## Compatibility

The `pgreact_api` inventory is a compatibility commitment beginning with
`0.8.0`. The `0.7.0` `pgreact` SQL API, manifests, worker command, and
terminology were provisional; they are not compatibility commitments and are
not preserved merely as aliases. The M11 replacement matrix is authoritative
for each retained, bridged, and removed `0.7.0` surface.

## Upgrade

The supported in-place migration is `0.7.0 -> 0.8.0`. It preserves the durable
rule, pack, derivation, activation, episode, lease, fact, support, provenance,
frontier, stratum, evidence, and history state. Use the `pgreact_api` facade
after upgrading; do not build new integrations on provisional `pgreact` calls.
There is no downgrade path. Restore the tested pre-upgrade physical backup to
roll back.

## Unchanged support boundary

This release does not expand the M10 boundary: PostgreSQL 18.3, pg_trickle
0.81.0, pgrx 0.18.0, Linux `amd64`, `READ COMMITTED`, coordinator-owned
`DIFFERENTIAL`, non-null `bigint` keys, physical recovery, and no RLS source
views. Worker protocols 1 and 2, existing resource limits, and the
external-effect model are unchanged.
