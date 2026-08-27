# M37 compatibility matrix

| Input or policy pair | Result |
|---|---|
| Same target kind and name; compatible M36 source and identity | Supported |
| `NULL` candidate | Supported; compares the deployed policy with itself |
| Different target kind or name | Rejected with `M37_INCOMPATIBLE_TARGET` |
| Different source relation, identity, or schema | Rejected by M36 validation |
| Missing or stale row image | Rejected by M36 validation |
| RLS source or missing `SELECT` permission | Rejected by M36 validation |
| More than two versions, reconstructed history, or durable job | Not supported |
| Why-changed causal explanation | Not supported by M37; owned by M38 |
