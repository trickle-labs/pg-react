# M39 benchmark profile

M39 measures semantic work separately from wall-clock time. The semantic
counters and digests must be reproducible; `elapsed_ms` may vary.

| Profile | Production-shaped workload | Bound | Required observations |
|---|---|---:|---|
| Order review | 1,000 order facts, 1 changed value, one rule | 100 evidence rows | rows copied, changed rows, causes, digest, memory |
| Candidate routing | 10,000 candidate rows, 100 subjects, two policy sides | 1,000 evidence rows | side alignment, fan-out, depth, temporary storage |
| Policy membership | 100,000 facts, 1,000 replay steps | configured replay limits | partial state, reached bound, replay work, checksums |

The corpus records the exact inputs, semantic output, findings, identities,
digests, bounds, costs, source checksum, authoritative checksum, and disposable
production-oracle result for every applicable operation. A release must record
the dominant scans, row copies, replay work, difference expansion, cause
expansion, memory, and temporary storage for all three profiles.
