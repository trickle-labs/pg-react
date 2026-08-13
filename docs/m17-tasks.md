# M17 author and operator tasks

Authors append one `window` object to an inherited aggregate declaration and
append the `bigint` window ordinal to the derived relation key. Preview and
deploy use the existing `pgreact_api.preview_program` and
`pgreact_api.deploy_program` calls.

Operators request and inspect progress with:

```sql
SELECT pgreact_api.request_watermark(
  'risk.windows', 'risk.item_source', 'occurred_at', '2026-08-13T12:00:00Z');
SELECT * FROM pgreact_api.watermark_status('risk.windows');
```

Inspect `pgreact.window_evidence` for current summaries and page corrections
with an explicit limit. On `M17_INPUT_FINALIZED`, restore the authoritative row
to the finalized state and call `pgreact_api.reconcile_program`. Export logical
state before dump/restore and retain the physical backup through the published
history floor.
