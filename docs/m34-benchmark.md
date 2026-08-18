# M34 benchmark profile

The packaged qualification profile measures a small fixture, a representative
fixture, and the configured evidence limit with `tests/m34.sh`. The public cost
object reports rows considered, affected subjects, dependency fan-out,
reevaluation, cascade depth, would-be work, elapsed time, memory (when
available), and temporary storage.

M34 does not promise a universal latency number. A candidate is acceptable
when it stays inside the published M33 resource limits, labels truncation,
and fails before unsafe work when a limit or source check cannot be satisfied.
