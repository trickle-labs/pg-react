# M21 evidence

The executable gate is:

```text
tests/m21.sh fast pg-react:v0.18.0
tests/m21.sh complete pg-react:v0.18.0
```

The gate freezes the release identity, fresh-install policy defaults, role
boundaries, preview classifications, protected active truth, bounded apply,
tombstone audit, idempotent no-op behavior, and populated direct upgrade from
`0.17.0`.

M21 does not ship partitioning or speculative catalog rewrites. Every covered
family records the inherited layout and the decision that no M18/M21 benchmark
has shown a measured advantage worth a physical migration. Retention batches
still expose table/index growth and vacuum/analyze state through public status.

The inherited M0–M20 semantic and recovery gates remain prerequisites for
publishing `v0.18.0`; the M21 gate adds the retention-specific evidence above.
