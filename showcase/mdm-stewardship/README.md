# MDM stewardship read-only package

Run the fixture-only read path from the repository root:

```text
psql -f showcase/mdm-stewardship/01-fixture.sql
psql -f showcase/mdm-stewardship/02-read-only-package.sql
```

The fixture is in `mdm_fixture`, never `mdm_steward`. It demonstrates immutable
package revisions, winner/tie/no-candidate/protected/no-op routing, opening-time
validation, deadline preservation, and bounded no-effect comparison.

Live routing and MDM publication remain blocked until pg-mdm M1 installs the
authorized `mdm_steward.policy_cases_v1` projection. No intent submission or
private-catalog access belongs in this showcase.
