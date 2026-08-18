# M33 benchmark profiles

The benchmark is reproducible rather than a universal throughput promise.

| Profile | Data / rules | Required measurements |
| --- | --- | --- |
| Small operational database | small dataset and ordinary rule set | coordinator, incremental change, status, explain, work claim, recovery |
| Moderate rule workload | representative joins, matches, policies, and pending work | median/p95 latency, throughput, storage, memory, WAL |
| Supported boundary | published support limits | same metrics plus recovery duration and limit behavior |

Record PostgreSQL configuration, hardware, architecture, image digest, data
volume, rule/match/policy counts, eligible subjects, derivations, pending
work, change rate, and coordinator cadence. Investigate median regressions over
10% and p95 regressions over 20%; publish and approve any accepted exception.
