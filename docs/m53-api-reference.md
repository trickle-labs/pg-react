# Package API reference

The package APIs are names-first and return JSON or typed declarations that can
be inspected in PostgreSQL.

```sql
pgreact.shared_condition(name, source, key_columns, maintenance_mode)
pgreact.parameter_family(name, parameter_relation, parameter_key,
                         parameter_value_columns)
pgreact.policy_set(name, version, members, applicability, subject_keys,
                   support, dependencies, valid_from, valid_to, evidence_limit)
```

`members` contains `rule` and `decision_program` declarations. `support`
contains `shared_condition` and `parameter_family` declarations. Each
dependency is an object with typed `from` and `on` identities.

```sql
SELECT pgreact.preview(package_declaration);
SELECT pgreact.validate(package_declaration);
SELECT pgreact.deploy(package_declaration, jsonb_build_object(
    'plan_digest', preview_result #>> '{summary,plan_digest}'));
SELECT pgreact.status('checkout-risk');
SELECT pgreact.compare(package_declaration);
SELECT pgreact.semantic_diff(package_declaration);
SELECT pgreact.doctor('checkout-risk');
SELECT pgreact.explain('checkout-risk');
SELECT * FROM pgreact.policy_set_contents WHERE name = 'checkout-risk';
SELECT * FROM pgreact.policy_set_dependencies WHERE name = 'checkout-risk';
SELECT pgreact.export('checkout-risk', 'policy_set', '2026-09');
SELECT pgreact.import(exported_document);
SELECT pgreact.remove('checkout-risk');
```

Validation reports stable finding codes. The most useful package findings are
`M53_POLICY_MEMBER_LIMIT`, `M53_POLICY_DEPENDENCY_ENDPOINT`,
`M53_POLICY_DEPENDENCY_CYCLE`, `M53_POLICY_APPLICABILITY`, and
`M53_POLICY_PAYLOAD_LIMIT`. If preview returns `ADOPT`, pass the exact child
identity in `preconditions.adopt` before deploying.

The names-first explanation helpers delivered in the same milestone are
documented in [the ergonomics contract](m53-ergonomics-contract.md).
