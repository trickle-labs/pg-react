# M42 contract: evidence snapshots

M42 is extension `0.39.0`. It keeps one complete M41 causal-path answer after
the source evidence used by that answer is no longer available.

## Declaration policy

Add `evidence_snapshot` to a canonical `decision_program` declaration to opt in:

```json
{"evidence_snapshot":{"retention_seconds":2592000}}
```

`enabled` is optional and defaults to `true`. `retention_seconds` must be a
positive integer no greater than `3153600000` seconds. A missing policy or a
policy with `enabled: false` stores no snapshot. Other declaration kinds cannot
use this field.

The policy is part of the normalized declaration and its digest. A snapshot
keeps the declaration digest and the digest of the policy used at capture.
The snapshot and audit tables enable and force row-level security. Owner and
operator checks remain explicit in every public operation, so an unauthorized
request fails closed.

## Capture

```sql
pgreact_api.capture_evidence_snapshot(
    target pgreact_api.target,
    subject jsonb,
    root jsonb,
    capture_key text
) returns jsonb
```

`target.kind` must be `decision_program`. `target.version` must be the public
decision version. `subject` must contain one bigint business key. `root` must
contain exactly `root_kind: decision_result` and a decimal `result_key`.
`capture_key` is one to 128 characters from letters, digits, `.`, `_`, `:`, and
`-`.

Capture calls M41 in the same PostgreSQL statement. Only a `complete` answer is
stored. The stored answer is unchanged. A partial, unavailable, unsupported,
or stale answer creates no row.

The public identity is the stable text value
`evidence_snapshot:<kind>:<name>:<version>:<root_identity>:<capture_key>`.
The root identity uses the canonical M41 decision-result identity. Retries use
the same row and return the same answer. A new key creates a new identity.

## Read and delete

```sql
pgreact_api.read_evidence_snapshot(
    target pgreact_api.target,
    root_identity text,
    capture_key text
) returns jsonb

pgreact_api.delete_evidence_snapshot(
    target pgreact_api.target,
    root_identity text,
    capture_key text
) returns jsonb
```

Read returns `available` before the eligibility time and
`deletion_eligible` after it. The `snapshot` member is the exact M41 answer.
The `metadata` member contains the target, root identity, subject, versions,
capture times, owner, and cost counters.

Delete is allowed to the declaration owner or the configured operator after the
eligibility time. It writes one retention tombstone and one audit row, then
removes the snapshot. Repeated deletion returns `deleted` without new state.

Missing, deleted, and unauthorized requests do not reveal the target, subject,
root, result, graph, owner, digest, or eligibility time. Authorized deleted
reads expose only the tombstone identity, outcome, digest, policy version, and
prune time.

## Retention and limits

The `evidence_snapshots` family is part of M21 preview, apply, status metrics,
audit, detail, and tombstone reporting. M21 never removes a snapshot before its
declared eligibility time. M42 stores one complete M41 answer and its payload
size. It does not add a second evidence format, automatic capture, enumeration,
search, source history, or database snapshot.
