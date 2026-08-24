# M31 contract — authoritative runtime

Status: the supported runtime paths are implemented and pass the local
complete evidence lane; the full milestone remains unqualified until every
release gate has evidence.

M31 is the runtime milestone after M30. In ordinary language, M30 records who
a policy set applies to; M31 must make that answer control the real rule
lifecycle and work. The answer must be durable, inspectable, atomic, and safe
when the source is invalid or changes underneath the system.

## Frozen inputs from M30

- Match identity is `match_keys`; subject identity is `subject_keys`.
- Keys contain one to four ordered, distinct, non-null components.
- Supported key types are `bigint`, `uuid`, and `text COLLATE "C"`.
- Codec version is 2.
- `GLOBAL` and `POLICY_SET_REQUIRED` are distinct scope modes.
- Eligibility is relational and bounded; the compatibility JSON array is not
  authoritative.
- A valid empty source is different from an invalid or inaccessible source.
- Existing M29 declarations must not become policy-set-gated silently.

M31 must consume this model without redefining identity or scope semantics.

## Implemented locally

`sql/m31.sql` adds the coordinator layer used by the packaged SQL: it refreshes
relational eligibility, records scope supports, gates effective rule
activations, withdraws affected work, handles sampled-time expiry and generic
policy-set removal, and exposes barriers through the ordinary façade.
`tests/m31.sql` covers a rule whose match key is `order_id` and whose policy
subject is `customer_id`, including entry, exit, return, expiry, removal,
invalid-source blocking, and overlapping policy sets.

## Authoritative behavior

The runtime must provide complete authoritative adapters for `rule`,
`decision_program`, and `policy_set`. A kind outside the supported adapter
registry must be rejected before any authoritative mutation. Metadata alone
must never be reported as deployed.

For a `POLICY_SET_REQUIRED` member:

1. The match identity identifies the member’s candidate facts.
2. The subject identity identifies the policy-set subject.
3. Eligibility is checked against the M30 relational eligibility rows.
4. A non-eligible subject has no effective member truth, winner, scoped
   derived support, lifecycle transition, or executable work.
5. Entry, exit, return, expiry, removal, and overlapping-set changes produce
   one coherent generation/revision and provenance record, without duplicate
   activation or work.

Eligibility and member changes must commit atomically across eligibility,
supports, effective truth, lifecycle, decisions, derivations, work, attempts,
frontiers, and explanations. If the runtime cannot establish that agreement,
it must fail closed and expose the barrier.

## Coordination and safety

The implementation must publish one total lock order covering deployment,
replacement, removal, claims, leases, recovery, and applicability changes.
Every claimed item must be revalidated before execution and after any relevant
applicability or source-drift boundary. Invalid, unauthorized, drifted,
incomplete, malformed, RLS-protected, and over-limit sources must fail closed
before unsafe partial mutation where possible.

Removal must be generic: it retires authoritative runtime behavior and applies
the required lifecycle, support, decision, and work transitions atomically.
The M29-to-M31 path must preserve valid history and must not silently activate
policy-set gating.

## Truthful ordinary operations

`validate`, `preview`, `deploy`, `run`, `remove`, `status`, `explain`, and
`doctor` must describe or change the same authoritative state. Read-only
operations must leave the authoritative checksum unchanged. Public views,
status, explanation, and doctor must agree, including barriers and incomplete
states.

## Explicit non-goals

M31 does not add PostgreSQL-native constructors, a second evaluator, policy
simulation, replay, backtesting, why-changed comparison, nested policy sets,
or a new policy language. Those are later work or remain excluded.

## Completion rule

This contract is complete only when the evidence in
[m31-evidence.md](m31-evidence.md) is green, the independent review has no
blocker, the five-person M32 cohort has recorded early feedback, and the
existing M0–M30 gates still pass. The local complete lane covers populated
upgrade/no-silent-gating, stale claimed-work withdrawal, race/lease behavior,
recovery, security, performance, retention, and the supported adapter paths.
The independent review, five-person M32 cohort, broader published
qualification record, and release artifact qualification are still open, so
M31 is not ready to tag or publish.
