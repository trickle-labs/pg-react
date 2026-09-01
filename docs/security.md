# Security

The current release is pg-react `0.43.0`. PostgreSQL permissions and ownership
remain authoritative. Configure separate author, operator, worker, reader, and
advanced-reader roles, and grant only the surfaces each role needs.

Review tokens contain a version, target identity, declaration digest, and
preview/plan digest. They contain no credentials or source rows. A token does
not bypass ownership, source, current-state, barrier, or stale-plan checks.

Database consequences run transactionally. Delivery outside PostgreSQL is at
least once and must be idempotent. Keep secrets out of declarations, source
views, logs, exported documents, and review tokens.
