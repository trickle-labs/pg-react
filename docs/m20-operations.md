# M20 operations

Use `pgreact_api.shared_condition_status()` for condition versions, frontiers,
consumers, drift, and fan-out cost. `doctor()` reports extension mismatch and
source drift. `reconcile_shared_condition(name)` reuses the durable derivation
reconciliation path. A replacement must keep the public row/key contract when
consumers are live; otherwise deploy the consumer changes together or remove
the consumers first.
