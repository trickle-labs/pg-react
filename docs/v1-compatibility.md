# v1 compatibility

The v1 promise starts at `1.0.0`. `0.30.0` is the qualification baseline, not
GA.

| Surface | v1 status |
| --- | --- |
| `pgreact.rule`, `decision`, `policy_set` | Ordinary and supported |
| `pgreact.validate`, `preview`, `deploy`, `remove`, `run`, `status`, `explain`, `doctor` | Ordinary and supported |
| `pgreact.rules`, `matches`, `decisions`, `policy_sets`, `work`, `attempts`, `health` | Ordinary and supported |
| `pgreact_api` wrappers | Compatibility; same runtime, not the teaching path |
| Advanced derivation, temporal, provenance, recovery, and retention APIs | Advanced or administrative, as listed in the inventory |
| `pgreact_internal`, `pgreact_runtime` | Internal; never a repair interface |

Patch releases contain fixes, security corrections, documentation, packaging,
and semantics-preserving performance work. Minor releases may add
backward-compatible optional features, views, columns, declarations, and
finding codes. Major releases are required for incompatible ordinary API or
semantic changes.

Existing declarations valid under v1 remain valid, or receive an explicit
versioned migration. Existing finding meanings and required view columns do
not change. A contract-affecting fix restarts the affected release-candidate
evidence.
