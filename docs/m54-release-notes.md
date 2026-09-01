# pg-react 0.43.1: qualified M54 correctness closure

pg-react now makes the current PostgreSQL-native product easier to use. The
current release is `0.43.1`; `1.0.0` remains postponed indefinitely.

## What users can do

- Follow one current installation and authoring path instead of a historical
  release-candidate guide.
- Use `change_columns` and `conflict_key_columns` through the ordinary rule
  constructor all the way to stored runtime behavior.
- Create or replace an active rule or decision with the same stable-name
  `validate`, `preview`, review, `deploy`, and inspect workflow.
- Turn a preview into `pgreact.review_token(result)` instead of hand-building
  digest preconditions. The token is review evidence, not a permission.
- Choose `DRAIN_OLD` or `CANCEL_OLD` explicitly when command-rule replacement
  has old executable work.
- Recover common rule work with stable names; UUID lookup is no longer part of
  the normal operator journey.
- Run tutorials deterministically with `pgreact.run()` while production still
  uses the PostgreSQL-managed worker asynchronously.

## Compatibility and limits

The existing JSON-preconditions deployment call and specialized compatibility
APIs remain installed. The adjacent update does not mutate deployments or
source data by itself. Existing bounded evidence, at-least-once external
delivery, and the current PostgreSQL support boundary remain unchanged.

The next milestone is selected from adoption evidence. M59 is the default
candidate when scale and recovery measurements block an operating decision;
M58, M45, M55, or M56 takes precedence when authorization, windows, schema
changes, or rebuild safety is the actual blocker.
