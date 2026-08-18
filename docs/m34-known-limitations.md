# M34 known limitations

> [!NOTE]
> Versioned `0.31.0` limitations retained for history. Use
> [`v1-known-limitations.md`](v1-known-limitations.md) for the current v1
> boundary.

- M34 compares current authoritative facts only; historical replay and
  hypothetical facts belong to later milestones.
- Evidence is bounded. When the limit is reached, counts for the delta are
  not presented as exact.
- External effects are never estimated as exactly-once. The result reports
  would-be work, not delivery cost or delivery success.
- Declaration kinds that cannot be evaluated through the frozen M33
  relational semantics fail closed rather than being approximated.
