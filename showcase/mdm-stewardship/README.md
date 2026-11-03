# MDM stewardship read-only package

Run the fixture-only read path from the repository root:

```text
psql -f showcase/mdm-stewardship/01-fixture.sql
psql -f showcase/mdm-stewardship/02-read-only-package.sql
```

The fixture is in `mdm_fixture`, never `mdm_steward`. It demonstrates immutable
package revisions, winner/tie/no-candidate/protected/no-op routing, opening-time
validation, deadline preservation, and bounded no-effect comparison.

This package intentionally remains a read-only fixture. It routes from
`mdm_fixture.policy_cases_v1` and does not demonstrate admissions,
`mdm.refresh`, or intent submission. The pg-react integration adapter uses the
authorized `mdm_steward.policy_cases_v1` projection, but production intake and
refresh batching remain outside this example. The bounded JSONL producer
reference for source admissions and refresh batching is documented in the
[pg-mdm integration guide](../../integrations/pg-mdm/README.md#bounded-jsonl-producer).
Its local workload evidence does not establish application deployment or release
qualification. No private-catalog access belongs in this showcase.
