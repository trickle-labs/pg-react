# M23 operations

Use `pgreact_api.temporal_status()` for current declarations, clock frontier,
and per-key state. Use `temporal_preview(name)` before authoring and
`temporal_explain(name, key)` for the complete declaration, boundary, state,
history, and lifecycle identity. `temporal_history(name)` is the append-only
operator view of observations and temporal transitions.

The managed coordinator calls the inherited `pgreact_api.run()` path. It
refreshes maintained inputs, advances the monotone database-time frontier, and
then evaluates pending temporal boundaries in the same transaction. A manual
operator can call `pgreact_api.run(finite_timestamptz)` for a deterministic
clock sample.

Pause before replacement or removal. Resume refreshes the maintained stream and
reconciles current state. If a source or state was restored, run
`reconcile_temporal_rule(name)` before trusting new work. `temporal_doctor()`
reports orphan state, backward-frontier drift, extension mismatch, and the
published key-pass limit.
