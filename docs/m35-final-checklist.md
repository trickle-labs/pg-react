# M35 final checklist

- [x] Extension metadata targets `0.32.0`.
- [x] Existing three-argument comparison functions remain unchanged.
- [x] Four-argument comparison functions accept ordered typed row changes.
- [x] Insert, update, delete, conflict, stale, duplicate, limit, and RLS paths are covered.
- [x] Results expose changed facts, digests, snapshot identity, checksums, cost, lifecycle, and work evidence.
- [x] The source and pg-react state remain unchanged after a simulation.
- [x] The upgrade pair is `0.31.0 -> 0.32.0`.
- [x] The release gate is `tests/m35.sh complete`.
- [x] Packaged M35 Docker qualification and inherited M34 qualification passed locally.
