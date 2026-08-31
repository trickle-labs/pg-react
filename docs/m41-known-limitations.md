# M41 known limitations

- M41 follows one current decision result or work item at a time.
- It only follows lifecycle, selection, applicability, modeled support, and
  authoritative-source links already recorded by pg-react.
- It cannot infer arbitrary SQL or query-plan lineage, explain application code,
  or describe what an external delivery consumer did.
- Ordinary source and detailed history are not retained for later questions;
  opt-in evidence snapshots are the proposed M42 candidate.
- Cycles, stale or pruned evidence, inaccessible sources, and resource limits
  produce explicit incomplete states.
- M41 is not a feature freeze or release-candidate cycle. M42 is only a
  candidate until M41 field evidence and user traction select it.
