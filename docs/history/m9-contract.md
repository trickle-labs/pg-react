# M9 stratified-negation contract

M9 is extension `0.6.0`. It adds safe keyed absence checks to M8 derivation
programs without changing positive M8 programs, facts, supports, or public
entry points.

## Program definition and graph

An M9 rule may add `negative_inputs`; omission is exactly `[]`. Each item has
exactly `relation` and `key`. `relation` is resolved through the rule-pack
`objects` mapping and names either an authoritative table/view or an active
derived relation. `key` must name one `bigint` column and must equal the rule's
non-null output key. This is the complete range-restriction rule: the value
tested by every negative input is already bound by the positive source row.

```json
{"name":"eligible","definition":"candidate","key":"id",
 "target":"eligible","version":1,
 "inputs":[{"relation":"reachable","key":"id"}],
 "negative_inputs":[{"relation":"denied","key":"id"}]}
```

The absence check is PostgreSQL `NOT EXISTS` with built-in `bigint` equality.
A checked `NULL` never equals the bound non-null key and therefore does not
block it. User-defined equality operators, expressions, extra predicates,
multi-column checks, general antijoins, `NOT IN`, `EXCEPT`, outer joins, and
negative aggregates are outside M9.

Every declared positive input is a `POSITIVE` edge and every declared negative
input is a `NEGATIVE` edge. Positive strongly connected components are the M8
components. A negative edge whose target can reach its source through any
polarity is rejected before mutation. Strata are the unique minimal stable
assignment: a positive edge does not raise the target, a negative edge raises
it by one, and each component receives the maximum weighted path ending at it.
Components and edges use their normalized relation and rule names for stable
identity; catalog OIDs are never part of the portable graph hash.

Validation, preview, deployment, replacement, removal, and promotion remain
complete rule-pack operations. The public graph and frontier surface is:

```text
pgreact.derivation_dependency_graph
pgreact.derivation_strata
pgreact.negative_dependency_evidence
```

The inherited `pgreact.derivation_programs`, `derivation_components`,
`derived_facts`, and support views remain authoritative. M8 definitions that
omit `negative_inputs` produce byte-identical M8 graphs and results.

## Evaluation and truth maintenance

At refresh, pg-react locks every checked relation, validates its frozen
identity, and rebuilds the complete program in `(stratum, component, rule)`
order. Each component reaches its positive least fixed point over completed
lower strata. All strata commit at one program frontier. A lower insertion can
remove a higher support and a lower removal can create it; failed evaluation,
resource exhaustion, or drift leaves the prior complete frontier unchanged.

A satisfied absence check creates evidence attached to the logical support,
not a fact. Its stable identity is `(program version, rule version, negative
input ordinal, semantic key)`. Public evidence contains the checked relation,
semantic key, source and target strata, and the completed lower-stratum
frontier. Blocking invalidates the evidence and its support together.

Downstream constraint and command rules continue to observe only committed
public derived relations. Equivalent delta and scheduling orders therefore
coalesce to the same lifecycle transition at the same complete program state.

## Explanation, repair, and recovery

`pgreact.explain_recursive_fact` keeps its signature. Each support adds a
`negative_checks` array after its positive `inputs`; positive M8 supports use
an empty array. A check contains evidence identity, relation, semantic key,
source stratum, and lower frontier. Absence is never emitted as a fact or a
proof leaf.

Reconciliation additionally diagnoses missing, extra, stale,
wrong-stratum, and wrong-frontier negative evidence or graph state, restores
the normalized graph and exact stratified result, and makes a second repair a
no-op. Retention preserves the active evidence required by every current
explanation.

The only supported in-place upgrade is `0.5.0 -> 0.6.0`. Crash restart and the
inherited physical-restore workflow preserve or reconcile programs, polarity
edges, strata, frontiers, facts, supports, negative evidence, provenance, and
downstream lifecycle state. The inherited platform, security, RLS, key-codec,
worker, execution-mode, and compatibility boundaries do not expand.
