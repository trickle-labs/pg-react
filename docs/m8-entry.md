# M8 entry fixture

M8 targets extension `0.5.0`. This fixture freezes its semantic workload and
normalized results before public SQL signatures are designed. The inherited
support boundary remains `linux/amd64`; no compatibility expansion is implied.

## Reference program

Every authoritative and derived relation has row type `(id bigint)` and
semantic key `id`. The fixed input is `id = 7` in independent authoritative
relations `left` and `right`. Program V1 contains these positive rules:

| Rule | Input | Target |
| --- | --- | --- |
| `left_to_a` | `left` | `A` |
| `right_to_a` | `right` | `A` |
| `a_to_b` | `A` | `B` |
| `a_to_c` | `A` | `C` |
| `b_to_c` | `B` | `C` |
| `c_to_d` | `C` | `D` |
| `d_to_c` | `D` | `C` |

Component and row order is fixed as shown below. Every component in a row is
at that row's frontier.

```text
program|frontier|operation|components|facts|support_counts
V1|1|insert left(7),right(7)|[A],[B],[C,D]|A(7),B(7),C(7),D(7)|A(7)=2,B(7)=1,C(7)=3,D(7)=1
V1|2|remove left(7)|[A],[B],[C,D]|A(7),B(7),C(7),D(7)|A(7)=1,B(7)=1,C(7)=3,D(7)=1
V1|3|remove right(7)|[A],[B],[C,D]|empty|empty
V1|4|restore right(7)|[A],[B],[C,D]|A(7),B(7),C(7),D(7)|A(7)=1,B(7)=1,C(7)=3,D(7)=1
V2|1|replace V1: remove a_to_c,d_to_c|[A],[B],[C],[D]|A(7),B(7),C(7),D(7)|A(7)=1,B(7)=1,C(7)=1,D(7)=1
V3|1|replace V2: restore a_to_c,d_to_c|[A],[B],[C,D]|A(7),B(7),C(7),D(7)|A(7)=1,B(7)=1,C(7)=3,D(7)=1
```

V1, V2, and V3 are immutable program versions. Replacement commits the new
graph, components, supports, facts, and frontier atomically.

## Frozen explanation

Explanation expands every active alternative in rule order and stops at
authoritative input or the first repeated fact. V1 frontier 1 explains `C(7)`
exactly as follows:

```text
C(7)
  a_to_c <- A(7)
    left_to_a <- left(7)
    right_to_a <- right(7)
  b_to_c <- B(7)
    a_to_b <- A(7)
      left_to_a <- left(7)
      right_to_a <- right(7)
  d_to_c <- D(7)
    c_to_d <- C(7)
      cycle C(7)
```

At V1 frontiers 2 and 4 the two `left_to_a` lines are absent. At frontier 3
the explanation is SQL `NULL`. The repeated `C-D` edge is represented once by
`cycle C(7)`; it never grounds a fact without an authoritative path. V2 has
only the `b_to_c` path, and V3 again has all V1 frontier-4 alternatives.

## Rejection fixtures

Each program below is rejected before catalog or runtime mutation:

| Fixture | Construct | Required classification |
| --- | --- | --- |
| `negative_not_exists` | `NOT EXISTS` over a derived input | non-monotone |
| `negative_aggregate` | aggregate or `GROUP BY` over a derived input | aggregate |
| `negative_outer_join` | outer join over a derived input | unsupported join |
| `negative_anti_join` | anti join over a derived input | non-monotone |
| `negative_recursive_cte` | recursive CTE | explicit recursion |
| `negative_set_generator` | set-generating input | unbounded generation |
| `negative_invented_key` | recursive rule that derives a new key | value invention |
| `negative_unresolved_nested` | unresolved source view name | unresolved dependency |
| `negative_undeclared_nested` | resolved but undeclared nested dependency | undeclared dependency |

## Atomicity, reconciliation, and recovery

For the V1 frontier-3 to frontier-4 transition, an injected evaluation error
after any iteration or a resource-limit failure leaves the exact frontier-3
empty state visible, changes no support, explanation, or downstream state, and
records one actionable failure. Retrying without the fault produces the exact
frontier-4 row above.

At V1 frontier 4, reconciliation fixtures inject missing, extra, stale,
circular-only, and wrong-frontier fact/support state. Reconciliation restores
the exact frontier-4 components, facts, counts, grounded explanation, and
downstream state, reports every repair through public diagnostics, and is a
no-op with no diagnostics on a second run.

A downstream observer of `D` records exactly `ACTIVATE(7)` at frontier 1, no
event at frontier 2, `DEACTIVATE(7)` at frontier 3, and a new `ACTIVATE(7)` at
frontier 4. It never observes partial component evaluation. V1-to-V2 and
V2-to-V3 replacement produce no downstream event because `D(7)` stays current.

Direct `0.4.0 -> 0.5.0` upgrade preserves all inherited M7 state before this
workflow runs. Crash restart and supported physical restore at V1 frontier 4
must reproduce byte-exact programs, components, frontiers, facts, supports,
provenance, explanation, dependencies, and downstream history; the next
refresh is a no-op.

## Entry gate evidence

Verified on 2026-08-09: public tag `v0.4.0` resolves to exact commit
`7dfaabdd44b39813d5a1345444d527321cf3ff9b`. Release workflow run
`31328677209` passed before publication. The published archive SHA-256 is
`82e5184bd98768cc7e12706d3bba3b375f47a9719c9de6529cbeed88943c9573`, and
the public `linux/amd64` image resolves to OCI digest
`sha256:bad3933f947bdddc9ffa08b6e1175c376ee8d6e6a0af4a5fd458c5cfda02a3d3`.
The M8 release entry gate is satisfied and product work may begin.
