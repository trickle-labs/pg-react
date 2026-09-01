# M43 final checklist

- [x] Extension metadata targets `0.40.0` and the managed worker accepts it.
- [x] One bounded read-only `pgreact_api.semantic_diff` operation compares canonical declarations.
- [x] Rule, decision-program, and policy-set field inventories are versioned and executable.
- [x] Added, removed, changed, typed, ordered-list, keyed-set, time, identity, default, null, and absent values are covered.
- [x] Opaque relation and function evidence is separate and assigns no SQL meaning.
- [x] Limits, findings, authorization, changed-state checks, costs, and stable digests are included.
- [x] M43 contract, API reference, inventories, examples, compatibility, benchmark, migration, evidence, limitations, corpus, and release notes exist.
- [x] `tests/m43.sh` checks fresh install, populated upgrade, rollback, and the M43 corpus.
- [ ] The externally supplied financial-exception or access-drift entry-gate review is recorded.
- [ ] Publish `v0.40.0` only after the external review and complete release workflow pass.
