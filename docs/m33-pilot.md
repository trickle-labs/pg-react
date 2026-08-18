# M33 controlled pilot record

Before `1.0.0`, two deployments distinct from the maintainer's development
database must exercise real application tables, a command rule, replacement,
action failure or injected failure, retry/recovery, backup/restore, upgrade,
restart, `doctor`, and ordinary monitoring. Together they must also exercise
policy scoping or decisions, and one pilot must be operated substantially by a
non-implementer.

For each pilot record the exact artifact digest, support tuple, setup,
observe/diagnose/repair/verify transcript, findings, and final disposition.
No pilot may repair private catalogs.
