# M9 readiness

## Repository state

The `0.6.0` repository candidate implements safe range-restricted keyed
negation, polarity-labeled dependency graphs, deterministic strata, ordered
fixed-point maintenance, deletion-sensitive support, finite negative evidence,
exact repair, atomic rule-pack lifecycle, and direct `0.5.0 -> 0.6.0` upgrade.
The inherited support boundary is unchanged.

`tests/m9.sh pg-react:v0.6.0` runs M0-M8 first, then the exact M9 validation,
lifecycle, scheduling, replacement, removal, explanation, repair, author,
upgrade, crash-restart, and physical-restore checks. Fresh `0.6.0` installation
SQL is mechanically identical to the `0.5.0` installation followed by the M9
upgrade script.

## Entry and release state

The M9 entry gate is satisfied by the exact public `v0.5.0` tag, successful
release run, archive checksum, `linux/amd64` OCI digest, disclosures, and direct
upgrade evidence recorded in `docs/m9-entry.md`.

Publication of `0.6.0` is not part of this milestone commit. Build the archive
and image from this exact commit, run `tests/m9.sh` against those bytes, publish
them, and record their immutable checksum and digest.

No M10 is defined. Unstratified negation, recursive aggregation, temporal
semantics, new execution modes, and support-matrix expansion remain outside M9.
