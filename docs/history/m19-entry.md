# M19 entry and reference fixture

The release candidate uses the pinned PostgreSQL 18.3 / pg_trickle 0.81.0
tuple. The exact automated entry command is:

```text
tests/m19.sh fast pg-react:v0.16.0
```

The reference fixture is `tests/m19-immediate.sql`. It covers non-superuser
authoring, exact join and key-shape rejection, scheduled default, same-
statement constraint visibility, deactivate/savepoint rollback, failed
statements, a two-member finite positive chain, repeated-key changes, and the
public reader observer.

The complete direct-upgrade fixture is `tests/m19-upgrade-before.sql` followed
by `tests/m19-upgrade-after.sql` through:

```text
tests/m19.sh complete pg-react:v0.16.0
```
