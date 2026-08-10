# M9 entry fixture

M9 targets extension `0.6.0`. This fixture freezes its reference workload and
normalized public results before product SQL changes. The inherited support
boundary remains `linux/amd64`.

## Reference program

Every fact row is `(id bigint)` with semantic key `id`. Authoritative `seed`
starts with `7`; authoritative `blocked` starts empty and may also contain
`NULL`. Program V1 contains:

| Stratum | Rule | Positive input | Negative input | Target |
| --- | --- | --- | --- | --- |
| 0 | `seed_to_candidate` | `seed` | — | `Candidate` |
| 0 | `candidate_to_reachable` | `Candidate` | — | `Reachable` |
| 0 | `reachable_to_candidate` | `Reachable` | — | `Candidate` |
| 0 | `blocked_to_denied` | non-null `blocked` | — | `Denied` |
| 1 | `reachable_unblocked` | `Reachable` | `Denied(id)` | `Eligible` |
| 1 | `eligible_to_alert` | `Eligible` | — | `Alert` |

The `Candidate`/`Reachable` cycle is grounded only by `seed`. Component order
is `[Denied]`, `[Candidate,Reachable]`, `[Eligible]`, `[Alert]`; normalized
public rows are:

```text
program|frontier|operation|strata|facts|support_counts|negative_evidence
V1|1|seed(7), blocked empty|0=1,1=1|Candidate(7),Reachable(7),Eligible(7),Alert(7)|Candidate(7)=2,Reachable(7)=1,Eligible(7)=1,Alert(7)=1|reachable_unblocked:Denied(7)@stratum0/frontier1
V1|2|insert blocked(7)|0=2,1=2|Candidate(7),Reachable(7),Denied(7)|Candidate(7)=2,Reachable(7)=1,Denied(7)=1|empty
V1|3|remove blocked(7)|0=3,1=3|Candidate(7),Reachable(7),Eligible(7),Alert(7)|Candidate(7)=2,Reachable(7)=1,Eligible(7)=1,Alert(7)=1|reachable_unblocked:Denied(7)@stratum0/frontier3
V2|1|replace: split positive cycle|0=1,1=1|Candidate(7),Reachable(7),Eligible(7),Alert(7)|Candidate(7)=1,Reachable(7)=1,Eligible(7)=1,Alert(7)=1|reachable_unblocked:Denied(7)@stratum0/frontier1
V3|1|replace: restore cycle and insert Audit stratum|0=1,1=1,2=1|Candidate(7),Reachable(7),Eligible(7),Alert(7),Audit(7)|Candidate(7)=2,Reachable(7)=1,Eligible(7)=1,Alert(7)=1,Audit(7)=1|reachable_unblocked:Denied(7)@stratum0/frontier1;alert_unaudited:Reviewed(7)@stratum1/frontier1
```

Inserting `NULL` into `blocked` leaves the complete frontier-1 facts,
supports, evidence, and explanation unchanged. Inserting `7` blocks exactly
`Eligible(7)` and `Alert(7)`. A source row with a null output key cannot create
a fact or negative check under the inherited non-null semantic-key contract.

## Frozen explanation

At V1 frontier 1, `Alert(7)` has this finite proof. UUID evidence identities
are compared separately to their deterministic derivation and are represented
here by `E1`.

```text
Alert(7)
  eligible_to_alert <- Eligible(7)
    reachable_unblocked <- Reachable(7)
      candidate_to_reachable <- Candidate(7)
        seed_to_candidate <- seed(7)
        reachable_to_candidate <- Reachable(7)
          cycle Reachable(7)
      negative E1: no Denied(7), source stratum 0 frontier 1
```

At frontier 2 the explanation is SQL `NULL`. At frontier 3 it is identical
except that the program and negative-check frontier are `3`. No node claims a
negative fact.

## Rejection fixtures

Every fixture is rejected before catalog or runtime mutation with its exact
classification:

| Fixture | Construct | Code |
| --- | --- | --- |
| `negative_cycle` | any cycle containing a negative edge | `PROGRAM_NEGATIVE_CYCLE` |
| `negative_unbound` | checked key differs from output key | `PROGRAM_NEGATIVE_UNBOUND` |
| `negative_unresolved` | checked relation does not resolve | `PROGRAM_NEGATIVE_UNRESOLVED` |
| `negative_duplicate` | same checked relation twice in one rule | `PROGRAM_NEGATIVE_DUPLICATE` |
| `negative_not_exists` | `NOT EXISTS` embedded in source SQL | `PROGRAM_ABSENCE_UNSUPPORTED` |
| `negative_outer_join` | outer/anti join absence idiom | `PROGRAM_ABSENCE_UNSUPPORTED` |
| `negative_except` | `EXCEPT` absence idiom | `PROGRAM_ABSENCE_UNSUPPORTED` |
| `negative_aggregate` | aggregate checked relation | `PROGRAM_NEGATIVE_AGGREGATE` |
| `negative_wrong_type` | checked key is not `bigint` | `PROGRAM_NEGATIVE_KEY_INVALID` |

## Atomicity, repair, and recovery

For frontier 1 to 2 and 2 to 3, repeated refresh, either equivalent source
delta order, and either component scheduling order produce the exact rows
above. An injected error after any stratum or a resource-limit failure leaves
the prior facts, supports, evidence, explanation, stratum frontiers, and
downstream state byte-exact; retry reaches the next row.

The downstream observer of `Alert` records `ACTIVATE(7)` at frontier 1,
`DEACTIVATE(7)` at frontier 2, and `ACTIVATE(7)` generation 2 at frontier 3.
It never observes `Denied(7)` together with `Alert(7)`.

Reconciliation fixtures inject missing, extra, stale, wrong-stratum, and
wrong-frontier support, evidence, graph, and fact state. One repair restores
the clean frontier-3 row and exact explanation; the second returns zero and
adds no diagnostics. V1 replacement, removal, stale preview, deployment
failure, concurrent refresh, and source or relation DDL leave no mixed graph.

Direct `0.5.0 -> 0.6.0` upgrade preserves the complete M8 fixture before this
workflow runs. Crash restart and physical restore at V1 frontier 3 reproduce
the exact normalized state; the next refresh is a no-op.

## Entry gate evidence

Verified on 2026-08-10: public tag `v0.5.0` resolves to exact commit
`2db3f672de4819912bfb3639f540c54cc75e628d`. Release workflow run
`31360174679` completed successfully. The published `linux/amd64` archive has
SHA-256 `dcf85850701e5df3e864c125166ca55b6690e5d6ad68b35c791d246e9be054a1`,
and `ghcr.io/trickle-labs/pg-react:v0.5.0` resolves to
`sha256:ba7402cbd056d9574d37badaf15b8ef88b634541ef2859387a65923b30a36eaa`.
The M9 entry gate is satisfied and product work may begin.
