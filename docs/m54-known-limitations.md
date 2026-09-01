# M54 known limitations

M54 improves adoption ergonomics; it does not add semantic or scale claims.

- The ordinary comparison codec remains limited to its existing bigint key.
- External effects remain at least once, not exactly once.
- Evidence and comparison remain bounded.
- RLS-backed evaluation, cross-database deployment, general workflows, and
  synchronous write-path actions remain outside the qualified boundary.
- M45 windows, M55 schema-change safety, M56 rebuild safety, M58 authorization
  alignment, and M59 supported-scale qualification remain later decisions.
