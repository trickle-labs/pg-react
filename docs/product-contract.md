# Product Contract

pg-react `0.46.0` keeps PostgreSQL authoritative for application facts,
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

Version 0.46.0 qualifies pg_trickle 0.105.2 with trigger CDC, explicit refresh
coordination, and the scheduler disabled. Stable Graph V1 and Delta V1 are
available upstream but unused by React. The approved MDM-STEWARDSHIP/1 contract
is fixture-tested; its optional adapter remains disabled until MDM M1 is shipped.
