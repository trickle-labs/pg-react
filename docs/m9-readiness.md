# M9 readiness

## Repository state

The released `0.6.0` extension implements safe range-restricted keyed
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

The published `v0.6.0` release is the exact M9 commit. Its successful release
workflow, checksummed archive, and immutable OCI digest satisfy M10's entry
gate; the verified values are recorded in `docs/m10-entry.md`.

M10 is defined separately in `ROADMAP.md`; no M10 product behavior is part of
this repository candidate. Aggregation, unstratified negation, temporal
semantics, new execution modes, and support-matrix expansion remain outside M9.
