# M18 readiness

M18 is ready only when `tests/m18.sh complete` passes, checksummed benchmark
and recovery artifacts are published, and the release/documentation audit
phases pass. `tests/m18.sh fast` is the ordinary-CI correctness profile;
`complete` runs the pinned benchmark and recovery profile.

Independent human usability evidence is not yet recorded. The remaining
external gate is an independently observed normal PostgreSQL developer
completing the same path in at most 15 minutes, with environment, role,
elapsed time, exact transcript/final state, and deviations archived under
`tests/fixtures/m18/human-usability.json`. The tag workflow validates this file
and refuses publication when it is absent or mismatched.

The release candidate is extension `0.15.0`; all inherited M0–M17 gates must
pass unchanged.
