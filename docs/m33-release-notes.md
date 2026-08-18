# M33 — v1 qualification and compatibility freeze

> [!NOTE]
> Historical `0.30.0` release record. Its original v1 sequencing is
> superseded: M34 / `0.31.0` is the v1 feature boundary and M35 is post-v1.
> Current users should start at [`index.md`](index.md).

`0.30.0` is the release that makes pg-react boring to depend on. It does not
add simulation, replay, or a new rule language. It checks that the existing
product is understandable, installable, upgradeable, recoverable, and safe.

## What changed

- the v1 contract now describes the real PostgreSQL interface, not the old
  `0.1.1` milestone;
- the supported PostgreSQL, pg_trickle, operating-system, packaging,
  isolation, replication, and RLS boundary is written down;
- direct and adjacent upgrade rehearsals preserve populated state and never
  run business work during `ALTER EXTENSION`;
- restart, restore, logical-restore, PITR, and promotion behavior have
  explicit recovery barriers and external-effect limits;
- the installed artifact can produce the API and finding inventories used by
  qualification;
- security, resource limits, public diagnostics, operational runbooks, and
  documentation examples are tested against the candidate package;
- release artifacts include checksums, an SBOM, provenance, and the evidence
  needed to create `1.0.0-rc.1`.

## What users need to know

The ordinary workflow is still: create a condition, declare a typed rule,
preview it, deploy it, run `pgreact.run()`, and inspect the public views.
External effects are still **at least once**, so consumers must deduplicate.
Unsupported environments fail with a diagnostic instead of being treated as
probably compatible.

## Release boundary

`0.30.0` is not GA. The next step is an exact packaged `1.0.0-rc.1`.
Only qualification fixes, packaging, documentation, and semantics-preserving
corrections are allowed in that cycle. Tag `v1.0.0-rc.1` only after the
complete M33 suite and the human usability/pilot records are green. Tag
`v1.0.0` only by promoting a fully qualified candidate without semantic
changes.
