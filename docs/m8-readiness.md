# M8 readiness

## Repository state

The `0.5.0` repository candidate implements positive derivation programs,
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

Publication of `0.5.0` is not part of this milestone commit. The next gate is
to build the archive and image from this exact commit, run `tests/m8.sh`
against those bytes, publish them, and record their immutable checksums and
digests.

No M9 is defined. After `0.5.0` publication, promote a later direction only
when demonstrated need, bounded prerequisites, a support matrix, and executable
exit evidence exist. Stratified negation is the closest semantic candidate,
not an approved M9.
