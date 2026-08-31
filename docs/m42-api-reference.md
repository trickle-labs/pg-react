# M42 API reference

## `capture_evidence_snapshot`

Call `pgreact_api.capture_evidence_snapshot(target, subject, root, capture_key)`
to retain one current decision result.

The result has `contract_version: 28`, `operation: capture`, `state`,
`snapshot_identity`, `snapshot`, `metadata`, and `findings`. A successful
capture has `state: available`. A retry has the same snapshot and an
`M42_CAPTURE_DUPLICATE` finding.

## `read_evidence_snapshot`

Call `pgreact_api.read_evidence_snapshot(target, root_identity, capture_key)`
to read retained evidence without reading source tables. The result state is
`available`, `deletion_eligible`, `missing`, or `deleted`.

## `delete_evidence_snapshot`

Call `pgreact_api.delete_evidence_snapshot(target, root_identity, capture_key)`
to remove eligible evidence. The result state is `deleted`, `available`,
`missing`, or `unavailable`.

## Policy validation

The canonical policy is:

```json
{"evidence_snapshot":{"enabled":true,"retention_seconds":2592000}}
```

`enabled` defaults to `true`. The retention value is finite, positive, and
bounded to one hundred years. Unknown fields return `M42_POLICY_INVALID`.

## M21 integration

`pgreact_api.retention_preview` reports `evidence_snapshots` rows and bytes.
`pgreact_api.retention_apply` removes eligible rows in bounded batches.
`pgreact_api.retention_audit` includes snapshot audit rows. The existing
operator and reader grants remain in force. Snapshot and audit tables use
row-level security in addition to the public function checks.
