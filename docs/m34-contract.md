# M34 contract — deployment-impact simulation

> [!NOTE]
> Versioned `0.31.0` milestone contract retained for history. Current users
> should use [`changing-policies.md`](changing-policies.md) and
> [`v1-api-reference.md`](v1-api-reference.md).

M34 targets extension `0.31.0`. It adds a read-only way to compare one
proposed declaration with one deployed target over the current authoritative
PostgreSQL snapshot. It does not deploy, run, enqueue work, call a
consequence, advance a frontier, or send an external effect.

## SQL surface

```text
pgreact.compare(proposed, deployed, options)
pgreact.compare_results(proposed, deployed, options)
```

`proposed` is a normal `pgreact_api.declaration`. `deployed` is a normal
`pgreact_api.target`; its kind and name must match the proposal. `options` may
contain `evidence_limit` from 1 through 1000 and `sampled_time`. The sampled
time must equal the current authoritative frontier; historical replay is not
part of M34.

`compare()` returns one envelope with `current`, `proposed`, and `delta`
arrays, plus `lifecycle` rows for affected transitions and `work` rows
describing would-be work. The arrays are bounded evidence. The envelope also
reports exact counts when complete, a declaration digest, source frontier,
sampled time, applicability snapshot, cost evidence, and before/after
authoritative checksums. `compare_results()` exposes the same rows as a
relational result stream for SQL filtering and joins.

## Supported behavior

Rules compare active semantic keys and bindings. Decision programs compare
subject, winner, priority, result, ambiguity, and would-be work. Policy sets
compare typed members and relational eligible subjects. Other declaration
kinds fail closed with `M34_UNSUPPORTED_KIND`; M34 never guesses.

The current side comes from the authoritative runtime views. The proposed
side reads the declared PostgreSQL sources with the same typed identity and
limit checks. Both sides require readable, non-RLS sources. Evidence is
bounded, deterministic, and marked incomplete when the limit is reached.

## Compatibility and safety

All M33 functions, views, finding meanings, declaration fields, and runtime
semantics remain unchanged. Comparison functions are `STABLE`,
`SECURITY DEFINER`, use a fixed `pg_catalog, pg_temp` search path, and are
granted only to configured author, operator, and reader roles. A changed
authoritative checksum aborts the comparison instead of returning a stale
answer.
