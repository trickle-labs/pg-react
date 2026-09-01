# M44 qualification evidence

The executable gate is `tests/m44.sh complete`. Its static lane checks the
`0.41.0` package, the no-op upgrade script, the contract documents, the
inventories, the matrices, the reference corpus, and shell syntax. Its
database lane runs the inherited M40 through M43 fixtures and the M44
cross-origin fixture.

The M44 fixture checks the public function identities, the current explanation,
why-not, causal-path, why-changed, and retained-answer results. It checks
public identity, evidence points, states, findings, limits, digests, costs,
read-only behavior, and the unchanged nested M41 answer.

The complete profile installs `0.41.0`, upgrades a populated `0.40.0` database,
and restores the pre-upgrade backup. Because M44 adds no runtime object, the
`0.40.0 -> 0.41.0` script makes no database change.

## External entry evidence

The repository contains three deterministic reference workflows for a
financial exception, access drift, and retained decision evidence. These
fixtures are repeatable test data. They are not an externally supplied review.

The M44 entry gate still requires one external financial-exception or
access-drift workload that uses at least two explanation origins. Record the
real review question, complete answers, manual identity mapping, state reading,
authorization check, retention check, and client reshaping here before
publishing `v0.41.0`.

The repository therefore makes no external-use claim until that record exists.
