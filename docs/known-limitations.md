# Known Limitations

The current release is pg-react `0.43.1`.

- External delivery is at least once, not exactly once.
- Comparison and evidence are bounded; large results may be partial.
- RLS-backed evaluation is outside the qualified boundary and is rejected.
- Comparison supports one non-null, unique `bigint` key for ordinary rules.
- Comparison does not measure dependency fan-out, reevaluation, cascade depth,
  memory, or temporary-storage capacity as supported limits.
- Command-rule replacement needs an explicit old-work policy when eligible
  work exists.
- The ordinary rule codec still requires one `bigint` semantic key.
- pg-react is not a synchronous write hook, distributed transaction
  coordinator, global-ordering service, or general workflow engine.
- Private schemas and internal UUIDs are not a supported application API.

See [Limits](limits.md) for numeric bounds and [Compatibility](compatibility.md)
for adjacent-release guarantees.
