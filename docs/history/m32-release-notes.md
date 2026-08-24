# M32 — PostgreSQL-native interface

M32 is the `0.29.0` package candidate. It gives ordinary PostgreSQL users one
task-first way to create and operate rules:

1. write a condition view;
2. declare a typed `pgreact.rule`;
3. `preview` it;
4. `deploy` it;
5. call the one global `pgreact.run()`;
6. inspect `pgreact.matches` and `pgreact.work`;
7. use `pgreact.explain` when a result needs an explanation.

The ordinary guide does not require hand-written JSON, copied UUIDs, private
catalog queries, or milestone-specific `run_*` functions. Names and business
keys come first; deeper engine identities remain available only for advanced
evidence.

## What is included

- extension identity `0.29.0`;
- the M32 PostgreSQL-native contract and API classification;
- stable finding-code names and actionable error guidance;
- migration notes for `0.28.0 -> 0.29.0`;
- a task-first README workflow and ordinary support matrix;
- inherited M31 qualification remains part of the CI and release lane.

## What this does not claim

This repository change does not create human-usability evidence. The required
five-person external usability exercise, broader evidence review, and
artifact qualification must be recorded before calling M32 release-ready.
No timing, completion rate, or participant result is claimed here.

M31 documents remain historical records of the predecessor milestone.
