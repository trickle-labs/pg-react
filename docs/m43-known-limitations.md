# M43 known limitations

- M43 compares one proposed declaration with one deployed target. It does not
  compare arbitrary JSON, databases, or a chain of versions.
- It reports modeled policy fields, not changed subjects, outcomes, work, risk,
  or business recommendations. M34 through M42 remain authoritative for those
  questions.
- SQL expressions, relation definitions, and function bodies remain opaque.
  M43 reports digest evidence but never interprets SQL or predicts its effect.
- The qualified rule and decision adapters retain their inherited bigint-key
  boundary. M43 does not broaden key support.
- No continuation token is returned for a partial result. Callers must raise a
  bound or narrow the declaration.
- Cost memory is unavailable and temporary storage is zero for this bounded
  in-memory operation; elapsed time is not part of semantic identity.
