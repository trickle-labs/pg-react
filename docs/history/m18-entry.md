# M18 entry and fixture manifest

M18 is extension `0.15.0`, entered only after the published `0.14.0` artifacts,
checksums, disclosures, OCI digest, SBOM (when available), direct-upgrade path,
and all M0–M17 gates are verified.

`tests/m18.sh` creates clean instances using
`tests/fixtures/m18/manifest.json`. The manifest pins versions, configuration,
clock inputs, roles, schemas, workloads, benchmark cases, entry artifacts, and
the executable SQL fixture that owns each exact declaration and state oracle.

The fixture includes risk/fraud, inventory, SLA/deadline, derived knowledge,
and event-time-window workloads. Frozen faults are incompatible configuration,
missing privilege, source/action drift, blocked frontier, worker loss during a
lease, failed work, interrupted watermark, repairable drift, crash/restart,
restore, and upgrade.

The small profile is the 10–15 minute authoring oracle. The populated profile
is the named benchmark matrix in `tests/fixtures/m18/manifest.json`.
