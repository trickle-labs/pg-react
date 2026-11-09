# Current SQL

`assembly.txt` lists the frozen 0.46.0 predecessor followed by the owner and
recovery migrations in `owner-recovery.sql`, `metadata-rebuild.sql`, and
`recovery-restore.sql`; the claim correction, managed-worker grants, pg_trickle
compatibility overlay, global temporal-key-cap guard, and temporary-DDL lock
exemption follow. The adjacent
upgrade also backfills the settings snapshot from existing configuration.
Published history remains frozen.

Starting from the actual published predecessor preserves coordinator locking
and the package-preview patch that differ from the older 0.43.3-based assembly.

The 0.46.2 fresh-install artifact and adjacent 0.46.1-to-0.46.2 upgrade are
assembled from these inputs. Focused temporal-limit
and missing-dispatcher recovery audits pass on fresh install and 0.46.0 upgrade
paths. A focused logical-restore audit on the merged pg-trickle #1288 candidate
also passes through pending-work delivery; it is not full release qualification.
Their observations are retained under
`tests/integrations/pg-mdm/evidence/v0.49-assembly-owner-recovery-local-20261030`
and `tests/integrations/pg-mdm/evidence/v0.49-dispatcher-recovery-assembled-local-20261030`.
Logical-restore evidence is retained under
`tests/integrations/pg-mdm/evidence/v0.49-logical-restore/assembled-1288-logical-restore-final-local-20261030`.
These runs do not qualify the full release profile.

The earlier temporary-DDL lock regression passed on fresh install and upgrade
paths, but used an unqualified temporary-table cleanup. The cleanup is now
schema-qualified and the broader name-based exception has been removed; rerun
`--binding-ddl-lock` on both paths before claiming this narrowed source. Prior
evidence remains under
`tests/integrations/pg-mdm/evidence/v0.49-binding-ddl-lock-local-20261030`.
The post-fix 300-offer diagnostic removes observed waits in this event trigger,
but still misses the 40/minute intake floor and due-latency limits; see
`docs/v0.49-qualification.md`.
