# M1 scale smoke baseline

The smoke fixture intentionally checks for architectural cliffs, not a release performance budget. Its published alpha baseline is 1,000 maintained matches, a 100-row activation burst (below the pinned differential threshold), one unchanged `DIFFERENTIAL` refresh, 16 constraint rules with one match each, three drained replacements, and at least 12.8 KiB of durable activation payloads.

Run it after the M0/M1 suite with `bash tests/m1-scale.sh`. The fixed shape makes regressions visible while M2 retains freedom to change worker and lifecycle internals. Production performance budgets remain M3 scope.
