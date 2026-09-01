# Versioning

The current release is pg-react `0.43.0`; `1.0.0` is postponed indefinitely.
Adjacent 0.x releases preserve valid ordinary calls by project policy. An
incompatible ordinary change requires an explicit compatibility decision,
prominent release notes, a migration path, and prior deprecation where
reasonable.

Use the extension version from `pg_extension`, not a milestone label, to select
an installation or upgrade path. The machine-readable
[current-release manifest](current-release.json) is checked against the
extension, container defaults, documentation, and release workflow.
