# M42 final checklist

- [x] Extension metadata targets `0.39.0` and the managed worker accepts it.
- [x] Canonical declarations validate and retain the opt-in policy in their normalized form.
- [x] Capture stores one complete, unchanged M41 decision-result answer.
- [x] Public identity includes target kind, name, version, root identity, and `capture_key`.
- [x] Read returns historical evidence and fail-closed missing, deleted, and unauthorized results.
- [x] Owner and operator deletion writes an audit row and stable tombstone after eligibility.
- [x] M21 preview, apply, metrics, audit, detail, and tombstone paths include snapshots.
- [x] M42 contract, API reference, inventories, examples, compatibility, benchmark, migration, evidence, limitations, and release notes exist.
- [x] `tests/m42.sh` checks fresh install, populated upgrade, and the M42 corpus.
- [ ] Publish `v0.39.0` only after the complete release workflow passes.
