# M30 contract — applicability foundation

M30 is extension `0.27.0`. It freezes the part of policy-set behavior that
answers **which subjects are eligible**. It stores that answer as ordinary,
indexed PostgreSQL rows and exposes it through public inspection views.

M30 is deliberately not the runtime milestone. It does not activate or
deactivate rule matches, create or withdraw work, or execute consequences.
Those changes belong to M31 and must use this contract without redefining it.

## Canonical identities

Members use `match_keys`, and applicability uses `subject_keys`:

```json
{
  "match_keys": ["order_id"],
  "subject_keys": ["customer_id"],
  "scope_mode": "POLICY_SET_REQUIRED"
}
```

Each identity has one to four ordered, distinct, non-null components. Supported
types are `bigint`, `uuid`, and `text COLLATE "C"`. The codec is version 2 and
keeps type and order in the identity, so `10` as a number is not the same key
as `"10"` as text.

The old `semantic_key`, `semantic_keys`, and scalar `subject_key` spellings are
accepted as compatibility aliases and are normalized to the canonical arrays.
New policy-set members must explicitly use `POLICY_SET_REQUIRED`; a `GLOBAL`
member cannot be silently gated.

## Frozen disposition

| Kind | Policy-set member |
| --- | --- |
| `rule`, `decision_program` | Fully authoritative in the eventual runtime |
| `derived_program`, `temporal_policy`, `effective_policy`, `parameter_family` | Supported with documented limits |
| `policy_set`, `shared_condition`, `decision_analysis`, unknown kinds | Unsupported and rejected before mutation |

M30 records this classification. M31 supplies the authoritative adapters and
runtime transitions.

## Relational state

`pgreact_internal.policy_set_eligibility` stores one row per eligible subject,
with the typed identity, ordered values, key types, codec version, complete
frontier, and source fingerprint. The old JSON array remains compatibility
evidence only; it is not the authoritative lookup.

`pgreact_internal.policy_set_scope_supports` is the frozen store for a future
exact member-match support. M30 creates no runtime supports. Public views expose
the empty support state, barriers, and migration classification without calling
one function per target.

## Limits and barriers

M30 keeps the M29 limits: 64 members per set, 100,000 eligible rows per source,
and evidence limits from 1 through 1,000. Null keys, duplicate identities,
unsupported types or collations, unavailable sources, row-level security, and
missing privileges are blocking findings. A valid empty source is different
from an invalid source.

## Ordinary workflow

```text
define -> validate -> preview -> deploy -> run -> status / explain / doctor
```

`run` refreshes only the foundation rows in M30. It does not claim lifecycle,
activation, work, or consequence semantics.
