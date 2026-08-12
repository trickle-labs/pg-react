# M14 reasoning tasks

Configure the existing four roles and one advanced evidence reader as the extension owner:

```sql
SELECT pgreact_api.configure_roles(
  'rule_author', 'rule_operator', 'rule_worker', 'rule_reader',
  'rule_advanced_reader');
```

Authors create their PostgreSQL type and definition view, declare the output relation, then preview and deploy a program without `inputs` fields. Operators run the existing coordinator and use `doctor` before making a repair. Readers use the `explain` overloads; only the advanced reader uses immutable IDs.

```sql
SELECT pgreact_api.doctor();
SELECT pgreact_api.explain('billing.open_fact', 42);
```

Stop coordinators and workers, take a physical backup, install `0.11.0`, run `ALTER EXTENSION pg_react UPDATE TO '0.11.0'`, then call the five-argument role configuration and verify `doctor` before resuming work.

