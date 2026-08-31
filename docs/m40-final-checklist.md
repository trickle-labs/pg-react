# M40 final checklist

- [x] Extension metadata targets `0.37.0`.
- [x] `why_not` is opt-in and legacy explain output is preserved when absent or false.
- [x] Rule, derived relation, decision, and relational policy-set adapters return bounded public evidence.
- [x] Complete, partial, unavailable, unsupported, and already-present states are explicit.
- [x] Causes, paths, findings, limits, semantic counters, and elapsed time are labeled.
- [x] Authorization and RLS keep their fail-closed behavior.
- [x] Why-not evaluation is read-only and does not retain evidence.
- [x] The `0.36.0 -> 0.37.0` migration and restore rollback record exist.
- [x] The M40 inventories, examples, benchmark, compatibility notes, and release notes exist.
- [x] `tests/m40.sh complete` passed against the exact packaged candidate.
- [x] Inherited M34 through M39 qualification passed in the complete candidate lane.
- [ ] Tag `v0.37.0` after the complete release workflow passes on the pushed commit.
