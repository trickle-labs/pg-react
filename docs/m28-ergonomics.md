# M28 API ergonomics policy

Ordinary documentation uses stable names and business keys, one declaration
shape, and the verbs `validate`, `preview`, `deploy`, `remove`, `run`,
`status`, `explain`, and `doctor`. Feature-specific routines remain in the
advanced compatibility reference.

A later milestone may add a new ordinary top-level verb only when an existing
verb, declaration kind, result section, public relation, or advanced API cannot
express the user operation safely and clearly. The exception requires an ADR
with the alternatives, compatibility impact, and usability evidence.
