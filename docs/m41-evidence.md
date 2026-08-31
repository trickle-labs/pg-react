# M41 qualification evidence

The release gate is `tests/m41.sh complete`. Its static lane verifies the exact
versioned SQL concatenation, inventories, finding registry, documentation,
read-only migration shape, and shell syntax. Its database lane verifies fresh
installation, inherited M40 behavior, decision-result paths, rule-work paths,
decision-work paths, invalid roots, and the adjacent `0.37.0 -> 0.38.0`
upgrade.

The conformance fixture checks returned object shape for root identity, node
kinds, paths, read-only behavior, stable findings, and legacy compatibility.
The packaged release workflow runs the same gate against the exact candidate
image and stores its logs with inherited qualification evidence.
