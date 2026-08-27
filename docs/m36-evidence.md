# M36 evidence

The M36 qualification lane is `tests/m36.sh complete`. It checks the versioned
SQL composition, public metadata, supplied initial rows, insert and update
steps, time-only progression, stale and nonmonotone rejection, bounded output,
checksums, no-effect behavior, and the populated `0.32.0 -> 0.33.0` upgrade
when Docker is available.

The SQL fixture checks the exact initial rows, transition deltas, final rows,
replay digest, relational result, unchanged source rows, unchanged pg-react
state, and the complete M36 finding registry. It performs no source DML during
a replay.

The local candidate `pg-react:m36-unreleased` passed the complete lane,
including the populated `0.32.0 -> 0.33.0` upgrade.

When the candidate image is unavailable, the script runs its static lane and
says that packaged qualification was not run. It does not claim Docker
qualification in that case.
