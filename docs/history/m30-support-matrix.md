# M30 support matrix

This is the frozen M30 applicability boundary. “M31” means the capability is
specified here but intentionally not claimed by the M30 release.

| Surface | M30 |
| --- | --- |
| Match identity | `match_keys`, one to four typed components |
| Subject identity | `subject_keys`, one to four typed components |
| Key types | `bigint`, `uuid`, `text COLLATE "C"` |
| Scope modes | `GLOBAL`, `POLICY_SET_REQUIRED` |
| Relation applicability | Supported; bounded, unique, non-null, authorized |
| Shared-condition applicability | Supported when the active condition and relation are available |
| Eligibility storage | Relational, indexed, codec v2 |
| JSON eligibility array | Compatibility evidence only |
| Scope-support storage | Frozen schema; no runtime transitions yet |
| Runtime barriers | Public schema and inspection; M31 execution semantics |
| M28 metadata-only declarations | `LEGACY_METADATA` |
| Existing M29 policy sets | `NEEDS_SCOPE_MIGRATION` |
| Existing delegated rules and decisions | `GLOBAL` |
| Nested policy sets | Rejected |
| Decision analysis as a member | Rejected |
| Lifecycle, work, claims, consequences | M31 |
| Simulation, replay, backtesting | Not in M30 |

The support matrix is a contract, not a promise that every supported member
kind already has authoritative ordinary-façade behavior. M31 must publish the
runtime evidence before claiming that result.
