# v1 deprecations

| Surface | Classification | v1 rule |
| --- | --- | --- |
| `pgreact` ordinary constructors, verbs, and views | Canonical | Full compatibility promise |
| `pgreact_api` released wrappers | Compatibility-only | Preserve; do not teach for new work |
| Worker, repair, recovery, and retention operations | Administrative | Supported only for their documented purpose |
| Advanced derivation, temporal, provenance, and analysis surfaces | Supported advanced | Semantic stability; presentation may evolve |
| Private catalogs and generated dispatchers | Internal | Never supported; no manual repair |
| Historical `0.1.1` “v1” documents | Historical | Do not interpret as the `1.0.0` contract |

No compatibility surface is removed in `1.0.0` merely to make the inventory
shorter. A future removal needs a warning, replacement, migration guidance,
and an announced earliest removal release.
