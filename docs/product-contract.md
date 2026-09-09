# Product Contract

pg-react `0.44.0` keeps PostgreSQL authoritative for application facts,
declarations, lifecycle, work, retries, and explanations. The PostgreSQL-managed
runtime is the normal production runtime; `pg-reactd` remains a compatibility
path.

The ordinary contract is:

```text
construct -> validate -> compare -> preview -> review -> deploy -> inspect
```

Review is advisory evidence, not authorization. Deployment rechecks ownership,
source definitions, declarations, work state, and safety barriers. Stable names
are the public identity; private UUIDs are implementation details.

M55 adds measured comparison provenance, one-pass rule-source validation,
deterministic current-SQL assembly, and qualification evidence. Version 0.44.0
adds no new evaluator or policy semantics.
