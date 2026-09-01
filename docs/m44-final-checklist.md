# M44 final checklist

- [x] Package metadata targets extension `0.41.0`.
- [x] The managed worker accepts extension `0.41.0`.
- [x] A versioned contract maps the five qualified explanation origins.
- [x] Shared vocabulary, public identity, state, ordering, digest, access, retention, limit, finding, and cost rules are documented.
- [x] Existing SQL calls remain unchanged. M44 adds no runtime function, wrapper, write path, or default option.
- [x] Contract, API reference, inventories, examples, compatibility, benchmark, migration, limitations, evidence, corpus, release notes, and checklist exist.
- [x] `tests/m44.sh` checks fresh installation, populated upgrade, rollback restore, and the M44 corpus.
- [x] Inherited M40 through M43 fixtures remain part of the complete M44 database lane.
- [x] The exact `0.40.0 -> 0.41.0` upgrade script is a no-op and the full install script concatenates correctly.
- [ ] An external financial-exception or access-drift review using at least two explanation origins is recorded.
- [ ] Publish `v0.41.0` only after the external review and complete release workflow pass.
