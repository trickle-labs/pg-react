# M36 final checklist

- [x] Extension metadata targets `0.33.0`.
- [x] `pgreact.replay` and `pgreact.replay_results` are additive public APIs.
- [x] Caller-supplied typed snapshots and ordered insert, update, delete, and time-only steps are supported.
- [x] Schema, identity, authorization, RLS, stale-image, duplicate, nonmonotone, finality, and resource limits are checked.
- [x] Initial, step, delta, lifecycle, work, and final results expose bounded evidence, digests, times, frontiers, checksums, and cost.
- [x] Successful and rejected replays leave source and pg-react state unchanged.
- [x] The upgrade pair is `0.32.0 -> 0.33.0`.
- [x] The release gate is `tests/m36.sh complete`.
- [x] Packaged M36 Docker qualification and the populated upgrade passed locally.
