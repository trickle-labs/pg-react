# M40 known limitations

- M40 answers one expected result for one deployed target and one subject.
- Rules, derived relations, and decisions use one bigint business key. Policy
  sets use the relational applicability adapter and the supplied subject JSON.
- M40 cannot explain arbitrary SQL predicates, deleted source history,
  unsupported views, or evidence hidden by authorization or RLS.
- A source row without an active rule match is unavailable until refresh. A
  stale policy frontier produces `partial`.
- M40 does not recommend repairs, prove necessity or sufficiency, retain
  evidence, or explain an end-to-end path. Those are later milestones.
