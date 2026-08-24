# M17 contract — event-time windows

M17 is extension `0.14.0`. Windowed public results use contract version `6`;
unwindowed M0–M16 calls retain their inherited output versions and shapes.

## Declaration and identity

One inherited aggregate input may add exactly one window:

```json
{
  "relation": "risk.item_source",
  "key": "account_id",
  "function": "SUM",
  "expression": "amount",
  "comparison": ">=",
  "threshold": 100,
  "window": {
    "event_time": "occurred_at",
    "duration": "PT1H",
    "allowed_lateness": "PT15M"
  }
}
```

The event-time column is a direct finite non-null `timestamptz`. Duration is a
positive fixed integral number of microseconds; lateness is fixed and
nonnegative. Years, months, computed timestamps, multiple windows, recursive
aggregation, and unqualified or unauthorized inputs are rejected atomically.

Windows are UTC-epoch-aligned and half-open. The derived key appends the signed
`bigint` ordinal `floor(epoch_microseconds / duration_microseconds)` to one to
three inherited group-key components. Only touched windows are materialized;
an emptied window remains through finalization.

## Watermarks, corrections, and finality

`pgreact_api.request_watermark(text,text,name,timestamptz)` records monotone
operator intent. `pgreact_api.watermark_status(text)` exposes requested and
complete values. The managed coordinator advances complete in
`pg_react.batch_size` batches, never splits one lateness boundary, and records
each finalization once. Equal requests are no-ops, backward requests fail with
`22023`, and standby requests fail with `25006`.

Each committed lower frontier creates one correction per affected window rule.
Identity is `program@version/rule@version/public-window-key/Ffrontier`;
replaying a frontier, watermark work, and repaired net-zero late input create
none. `pgreact_api.window_corrections(text,integer,text)` requires a limit in
`1..1000` and returns a stable cursor.

Input remains admissible while complete watermark is strictly before
`window_end + allowed_lateness`. A later authoritative change records
`M17_INPUT_FINALIZED`, sets the `LATE_INPUT` barrier, and leaves the last
complete facts, supports, corrections, finalizations, and downstream work
unchanged. Restore the source and call `pgreact_api.reconcile_program(text)`;
missing correction or finalization identity requires physical restore.

## Evidence, retention, security, and recovery

`pgreact.window_evidence` exposes finite current summaries without input-row
lineage. `pgreact.window_diagnostics` exposes versioned public diagnostics.
Readers may inspect status and current evidence; operators may request
watermarks, reconcile, prune, and export/restore logical state; advanced
readers may page correction history. Authors cannot advance time.

`pgreact_api.prune_window_history(text,timestamptz)` moves one monotone recovery
horizon. It removes only superseded corrections for finalized windows strictly
before the cutoff and never removes current summaries, latest corrections,
finalizations, lifecycle identities, pending-work evidence, or open-window
state.

`pgreact_api.export_window_state(text)` and
`pgreact_api.restore_window_state(jsonb)` are the bounded logical recovery
pair. Physical backup/restore remains authoritative for missing history.
Rollback is restore of the verified pre-upgrade physical backup; SQL downgrade
is unsupported. The supported direct upgrade is `0.13.0 -> 0.14.0`.
