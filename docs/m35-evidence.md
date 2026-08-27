# M35 evidence

The M35 qualification lane is `tests/m35.sh complete`. It checks the versioned
SQL composition, public metadata, typed insert, update, and delete changes,
ordered application, stale and duplicate rejection, bounded output, RLS
rejection, checksums, and the populated `0.31.0 -> 0.32.0` upgrade when Docker
is available.

The local candidate `pg-react:m35-unreleased` passed the complete lane, including
the populated `0.31.0 -> 0.32.0` upgrade. The available inherited
`pg-react:m34-unreleased` image also passed its complete lane, including the
populated upgrade and rollback checks.

The SQL fixture also checks that the result exposes the declaration digest,
change-set digest, source frontier, sampled time, source checksums, changed fact
images, causal evidence, cost fields, and the five M34 result sets. No fixture
performs source DML during a comparison.

When the candidate image or inherited image is unavailable, the script runs its
static lane and says that packaged qualification was not run. It does not claim
external Docker evidence in that case.
