# M38 final checklist

- [x] Extension metadata targets `0.35.0`.
- [x] `why_changed` is opt-in and false by default.
- [x] M34, M35, M36, and M37 public operations keep their signatures.
- [x] Non-`UNCHANGED` rows can carry a shared explanation object.
- [x] Unchanged rows receive no invented explanation.
- [x] Explanation evidence is transient and read-only.
- [x] The relational return types do not change.
- [x] The `0.34.0 -> 0.35.0` migration exists.
- [x] The M38 inventories, examples, benchmarks, compatibility notes, and
  release notes exist.
- [x] `tests/m38.sh complete` passed against the exact packaged candidate.
- [ ] Tag `v0.35.0` only after the complete packaged lane passes.
