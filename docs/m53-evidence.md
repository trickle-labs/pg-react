# M53 release evidence

The release gate is executable and has a static lane plus an optional
PostgreSQL 18 Docker lane.

```text
bash tests/m53.sh complete pg-react:m53-unreleased
```

The gate checks version identity, migration and full-install artifacts,
canonical package and ergonomics inventories, exact public signatures,
shell syntax, inherited M0-M44 fixtures, package validation, preview,
deploy/status/catalog, export/import digest checks, removal, and upgrade
metadata. It records evidence under `M53_ARTIFACT_DIR` when that variable is
set.

The repository fixture is repeatable qualification evidence. It is not a
substitute for a production change review using the operator's own policies.
