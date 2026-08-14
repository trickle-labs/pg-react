# M18 operations and day-2 procedure

`tests/m18-public-matrix.sql` freezes the healthy public `doctor`, name-first
program `status`/`explain`/watermark output, plus source-drift diagnosis and
repair. The inherited M0–M17 fixtures cover the remaining fault matrix.

The orchestrator loads a populated `0.14.0` workload, performs the administrator
upgrade, stops and resumes the managed worker, then runs `tests/m18-day2.sql`.
The frozen operator diagnoses worker loss and finalized-window drift, restores
the authoritative input, reconciles, advances the watermark, and proves the
exact post-upgrade result through public APIs.
