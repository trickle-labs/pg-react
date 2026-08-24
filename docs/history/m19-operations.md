# M19 compact operations

Validate before changing a declaration:

```sql
SELECT * FROM pgreact_api.validate_immediate_rule('app.active', 'id');
SELECT pgreact_api.preview_immediate_program(:definition);
```

Opt in only after the result is `OK` and the preview digest is recorded:

```sql
SELECT pgreact_api.author_immediate_rule('risk.active', 'app.active', 'id');
SELECT pgreact_api.deploy_immediate_program(:definition, :plan_digest);
```

Inspect the public boundary with `status`, `matches`, `explain`, and
`doctor`. An error names the object and remediation. Keep unsupported rules
scheduled; do not manually alter generated stream tables or private catalogs.
