# pg-mdm stewardship adapter

The v0.47 package is a read-only policy layer over the approved
`MDM-STEWARDSHIP/1` projection. It validates an authorized case relation,
publishes immutable React-owned policy revisions, and exposes deterministic
routing, elapsed-time deadline, and fixed-population comparison reads.

It never writes an MDM relation, calls `submit_policy_intent`, creates React
work, advances a lifecycle frontier, or invokes a refresh. Live qualification
still requires pg-mdm M1 to install `mdm_steward.policy_cases_v1`; fixture
qualification must use a separate schema.

Install the SQL files in order:

```text
integrations/pg-mdm/sql/policy-inputs.sql
integrations/pg-mdm/sql/routing.sql
integrations/pg-mdm/sql/deadline-preview.sql
integrations/pg-mdm/sql/comparison.sql
integrations/pg-mdm/sql/typed-flow.sql
```

The public seams are:

- `pgreact_mdm.validate_inputs(source_relation)` and
  `pgreact_mdm.policy_inputs(source_relation)` for the authorized projection.
- `pgreact_mdm.publish_package(policy_revision, package)` for immutable package
  publication and `pgreact_mdm.policy_document(policy_revision)` for review.
- `pgreact_mdm.route_cases(source_relation, policy_revision)` for winner,
  ambiguity, no-candidate, protection, and no-op explanations.
- `pgreact_mdm.deadline_preview(source_relation, policy_revision, captured_at)`
  for explicit-time deadline proposals.
- `pgreact_mdm.compare_population(...)` for complete or partial bounded
  comparisons with an explicit coverage manifest.

After the core extension is installed, load `typed-flow.sql` and pass the
returned `pgreact_api.declaration` to `pgreact.validate`, `pgreact.preview`,
`pgreact.review_token`, and `pgreact.compare`. The bridge adds the signed MDM
source as a typed policy support relation. The typed version includes the
published package digest, so route or deadline changes require a new revision
and declaration review. It does not deploy or run the declaration.
Run `tests/integrations/pg-mdm/v0.47-typed.sql` after the fixture test in a
database with the core extension installed to check that identity.

For installed MDM M1 qualification, bootstrap the upstream image with
`/tests/e2e.sql` and `/tests/e2e_policy.sql`, then run
`tests/integrations/pg-mdm/v0.47-live-setup.sql` followed by
`tests/integrations/pg-mdm/v0.47-live.sql` in a disposable joint database.

The package is adapter-owned and optional; the core pg-react extension remains
usable without it.
