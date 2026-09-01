# M53 known limitations

- A complete package accepts at most 64 members, 64 support declarations, 256
  dependency edges, and 1 MiB of canonical JSON.
- The source relation and parameter rows remain authoritative; packaging does
  not copy or rewrite those rows.
- Effective timestamps must be valid and non-overlapping for the package
  version being deployed.
- Cross-package dependency edges are intentionally rejected. Package all
  required declarations together.
- A package preview becomes stale after relevant DDL, deployment, removal,
  source change, or work change. Re-preview instead of retrying a stale plan.
- Restore-based rollback is required for the extension upgrade itself.
