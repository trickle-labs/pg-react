# M22 bounded support provenance contract

M22 is extension `0.19.0`, with a direct upgrade from `0.18.0`. It records
typed business bindings for the existing durable support graph and exposes a
finite proof without adding new truth or reasoning semantics.

## Public API

```sql
pgreact_api.provenance_validate(relation_version_id uuid) RETURNS jsonb
pgreact_api.provenance_preview(
  relation_version_id uuid,
  semantic_key bigint DEFAULT NULL,
  max_facts integer DEFAULT 100
) RETURNS jsonb
pgreact_api.provenance_status(relation_version_id uuid DEFAULT NULL) RETURNS jsonb
pgreact_api.provenance_doctor() RETURNS jsonb
pgreact_api.explain_provenance(
  relation_version_id uuid,
  semantic_key bigint,
  max_supports integer DEFAULT 100,
  continuation_token text DEFAULT NULL
) RETURNS jsonb
pgreact_api.explain_provenance_advanced(
  relation_version_id uuid,
  semantic_key bigint,
  max_supports integer DEFAULT 100,
  continuation_token text DEFAULT NULL
) RETURNS jsonb
```

`explain_provenance` returns contract version `10`, the fact, canonically
ordered supports and bindings, exact total/returned/omitted counts, a finite
proof node list, cycle/truncation state, retention-unavailability diagnostics,
and a snapshot-checked continuation token. The frozen bounds are 1,000
bindings per support, depth 32, 1,000 proof nodes, 1,000 supports per page,
and a 1 MiB payload budget.

## Binding identity

Each binding records the support, relation-version identity, relation name,
binding name, PostgreSQL type name, canonical JSON value, semantic key, fact
identity, whether the input is derived, and the inherited frontier/lifecycle
state. Physical tuple identity, display text, search path, and row order are
not identity inputs. Source bindings use the deployed source relation version;
derived bindings use the existing `derived_support_inputs` relation version and
fact identity.

Support triggers rebuild these rows in the same transaction as support and
input maintenance. The provenance table cascades with its support, so M21
retention cannot leave an orphan proof; an unavailable historical support is
reported rather than reconstructed.

For derivation programs, the response also carries the inherited bounded proof
summary: positive derived edges, cycle markers, negative lower-frontier checks,
aggregate count/comparison/threshold evidence, and the existing window
finality/correction summary when present.

## Authorization and boundaries

Readers, owners, operators, and advanced readers receive only the API surface
granted to their configured role. Advanced continuation uses the same snapshot,
authorization, count, depth, and payload ceilings. M22 does not provide
arbitrary SQL lineage, why-not reasoning, minimal-proof selection, proof
equivalence, physical-row tracking, unbounded traversal, recursive aggregation,
or M23 temporal semantics.
