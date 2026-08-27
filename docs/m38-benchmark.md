# M38 benchmark profiles

M38 uses the existing operation limits. The profiles below state the work that
the qualification fixture must measure.

| Profile | Input | Bound | Required observations |
|---|---|---:|---|
| Small rule | 1,000 rows, 1 changed value | 100 evidence rows | cause count, returned nodes, elapsed time |
| Decision review | 10,000 rows, 100 subjects | 1,000 evidence rows | candidate fan-out, path depth, temporary storage |
| Supported limit | 100,000 rows, 1,000 replay steps | configured operation limits | partial state, bound, memory, temporary storage |

The semantic counters are stable comparison values. `elapsed_ms` is measured
separately and may vary between runs. The qualification record must include the
originating result, the explanation digest, the no-mutation checksum, and the
public-SQL task time for each profile.
