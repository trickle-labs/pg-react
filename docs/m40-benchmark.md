# M40 benchmark

The qualification profile measures the bounded question in three
production-shaped workloads:

| Workload | Expected question | Dominant check |
|---|---|---|
| Financial exceptions | Which order did not enter review? | source lookup and rule support |
| Access drift | Which account is not eligible? | applicability and frontier |
| Order routing | Why did candidate 9001 lose? | candidate discovery and selection |

The result records semantic counters for candidate discovery, support checks,
evidence expansion, path depth, and returned causes. `elapsed_ms` is reported
separately because it depends on the machine and concurrent activity.

The published bounds are one target, one subject, path depth 1, at most 1,000
decision candidates, and at most 1,000 returned causes. A bound produces
`partial`; it never becomes a complete causal claim.
