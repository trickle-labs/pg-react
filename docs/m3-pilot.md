# M3 pilot evidence: manual-review queue

The RC pilot is the internal manual-review queue represented by the `m3` integration fixture. It uses a normal view, a typed `ACTIVATE` consequence, bounded claims, a group budget, and the coordinator-owned refresh path.

The exercise inserts a sustained 128-row activation burst, confirms one durable episode per activation, holds the group at one lease, validates the 30-second fairness window against newer high-salience work, tests an atomic backlog refusal, clears terminal payloads through the audited retention API, and simulates an OID rebuild while preserving activation identity and pending work. The same fixture then validates health/metrics and worker protocol compatibility.

This is an internal pilot, not a claim of external production adoption. An external pilot must repeat the same normal operation, load, worker-death, restore, and recovery exercises before GA.
