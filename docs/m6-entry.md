# M6 entry evidence

M6 product changes remain gated on two facts: publication of the exact
`v0.2.0` release and a reproducible demonstration that per-episode execution
overhead is the material bottleneck. `tests/m6-entry.sh` supplies the second
fact without changing the `0.2.0` product.

## Frozen entry workload

- Supported boundary: `linux/amd64`, PostgreSQL 18.3, `pg_trickle` 0.81.0,
  `READ COMMITTED`, coordinator-owned `DIFFERENTIAL`, non-null `bigint` keys,
  no RLS.
- Workload: 8,192 independent activations backed by one maintained view.
- Consequence: one idempotent, commutative database insert keyed by
  `episode_id`; no application computation or external I/O.
- Default sample: 4,096 episodes, each claimed and executed through the public
  single-episode API in its own transaction.
- Prototype sample: the same 4,096 episodes, 32 at a time in one transaction,
  still using the unchanged public claim and per-episode execution APIs with
  their eligibility, lease, binding, history, and effect writes intact.
- Entry threshold: the prototype must complete at least 1.5 times as many
  episodes per second, and default execution time per episode must exceed match
  maintenance time per episode. These are deliberately ratios so host speed is
  not part of the gate.

Run:

```console
tests/m6-entry.sh pg-react:m6-entry
```

The script also requires the exact 4,096 consequence rows from both paths.
It prints the two throughput measurements, their ratio, match and execution
milliseconds per episode, and the entry decision. The complete workload
identity remains queryable in `m6_entry.benchmark` for diagnosis.

On 2026-08-09, the verified local sample measured 90.57 default episodes per
second and 147.58 prototype batch episodes per second, a 1.63x improvement.
Match maintenance took 5.47 ms per episode versus 11.04 ms for default
execution, and the exact effect sets matched. This cleared the frozen 1.5x
materiality bar; the executable script remains authoritative for subsequent
machines.

## Failure scenarios fixed before the public contract

The M6 executable gate must cover an error in the first, middle, and last
episode; transaction abort before commit; worker death before invocation and
during invocation; lease expiry; ambiguous client disconnect; concurrent
source change; pause; `DRAIN_OLD` and `CANCEL_OLD` replacement; consequence and
dispatcher DDL; recovery barrier; crash restart; and supported physical
restore. Every scenario must compare exact normalized activations, lifecycle
events, agenda rows, attempts, diagnostics, and committed effects with the
single-episode path.

## Remaining entry gate

As of 2026-08-09, `v0.2.0` is not published in the GitHub repository. M6
product code must not merge until its release artifacts, checksum, OCI digest,
disclosures, and direct-upgrade evidence are published and independently
verified as required by `ROADMAP.md`.
