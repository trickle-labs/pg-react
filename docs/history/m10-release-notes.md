# pg-react 0.7.0 — stratified aggregation

Version `0.7.0` adds one keyed grouped `COUNT(*)` threshold dependency to
stratified derivation programs. Existing rules, workers, packs, positive
recursion, and keyed negation remain unchanged.

## What changed since 0.6.0

- Program rules may declare one range-restricted `aggregate_input` with a
  non-negative `bigint` threshold and `=`, `<`, `<=`, `>`, or `>=` comparison.
- Aggregate edges receive stable strata and cannot participate in a negative or
  aggregate cycle.
- Public aggregate evidence and explanations report the group key, exact count,
  comparison, threshold, and lower frontier without treating a summary as a
  fact or enumerating counted rows.
- The supported direct upgrade is `0.6.0 -> 0.7.0`.

## Artifact publication

A complete release publishes the immutable tagged `linux/amd64` OCI image,
`pg-react-v0.7.0-linux-amd64.tar.gz`, its SHA-256 manifest, the OCI digest,
these notes, and the full `tests/m10.sh` result.

## Known limitations

The support matrix remains PostgreSQL 18.3, pg_trickle 0.81.0, pgrx 0.18.0,
Linux `amd64`, `READ COMMITTED`, coordinator-owned `DIFFERENTIAL`, non-null
`bigint` keys, physical recovery, and no RLS source views. Aggregate cycles,
same-stratum and recursive aggregation, aggregates other than one `COUNT(*)`,
temporal aggregation, and aggregate-row lineage are unsupported.
