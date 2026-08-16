# pg-react 0.25.0 — one simpler way to use the same engine

M28 makes pg-react easier to learn without replacing the APIs that already
work.

Before M28, each feature had its own set of commands. Now ordinary users can
follow one path:

```text
define → validate → preview → deploy → run → status / explain
```

Declarations have a version, a kind, a stable name, and named fields. Preview
shows the normalized declaration and a digest. Deploy can require that exact
preview, so a changed source or stale review is refused instead of silently
deploying something different.

The new façade understands rules, derived programs, temporal policies,
shared conditions, effective-dated policies, parameter families, decision
programs, and decision analyses. It uses names first; immutable IDs remain
available when an operator deliberately needs historical evidence.

Existing M0–M27 functions, views, grants, and semantics remain available as
advanced or compatibility APIs. M28 does not add a proprietary policy
language, hide PostgreSQL relations, run a second evaluator, or grant generic
callers extra authority.

Upgrade directly from `0.24.0`:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.25.0';
```

This repository commit prepares the `v0.25.0` release. Tag and push `v0.25.0`
only after the release workflow has produced and verified the image, checksums,
SBOM, provenance, OCI digest, populated upgrade evidence, and complete
inherited gates.

The logical next milestone is M29 — Policy-set gating. It should add
versioned applicability through the same declaration, preview, deploy, and
inspection model.
