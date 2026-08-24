# M8 readiness

## Repository state

The released `0.5.0` implements positive derivation programs,
nested dependency validation, acyclic and strongly connected components,
bounded grounded least-fixed-point maintenance, stable recursive support-input
edges, finite explanations, exact reconciliation, atomic rule-pack lifecycle,
and direct `0.4.0 -> 0.5.0` upgrade. The inherited support boundary is
unchanged.

`tests/m8.sh pg-react:v0.5.0` runs M0-M7 first, then exact M8 lifecycle,
boundary, pack, rollback, upgrade, crash-restart, and physical-restore checks.
Fresh `0.5.0` installation SQL is mechanically identical to the `0.4.0`
installation followed by the M8 upgrade script. The pinned image build also
installs the native module used for non-executing rewrite-tree validation.

## Entry and release state

The M8 entry gate is satisfied by the exact public `v0.4.0` tag, successful
release run, archive checksum, `linux/amd64` OCI digest, disclosures, and direct
upgrade evidence recorded in `docs/m8-entry.md`.

The exact published artifacts, checksums, digest, and release qualification are
recorded in `docs/m9-entry.md`.
