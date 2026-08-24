# M32 API reference

This is the short reference for ordinary PostgreSQL use. The complete
machine-readable classification is [m32-api-inventory.json](m32-api-inventory.json);
stable findings are in [m32-finding-codes.json](m32-finding-codes.json).

## Ordinary authoring

| Operation | Use it for | Changes data |
| --- | --- | --- |
| `pgreact.rule(...)` | Build a typed named rule declaration | No |
| `pgreact.validate(...)` | Check a declaration without changing runtime state | No |
| `pgreact.preview(...)` | See normalized identity, counts, warnings, and blockers | No |
| `pgreact.deploy(...)` | Create or safely replace a declaration | Yes |
| `pgreact.remove(...)` | Retire a named object | Yes |
| `pgreact.run()` | Refresh truth and coordinate eligible work | Yes |

## Ordinary inspection

| Object | Question it answers |
| --- | --- |
| `pgreact.rules` | What rules exist and are they healthy? |
| `pgreact.matches` | Which business keys match now? |
| `pgreact.decisions` | Which candidate won, or why did none win? |
| `pgreact.policy_sets` | Which subjects are eligible? |
| `pgreact.work` | What durable work is pending, running, or failed? |
| `pgreact.attempts` | What happened during each work attempt? |
| `pgreact.health` | What needs operator attention across the installation? |

`pgreact.status(...)` answers what state a named object is in. Use
`pgreact.explain(...)` to learn why a business key is in that state. Use
`pgreact.doctor()` for installation and operational blockers.

## Advanced and compatibility APIs

Advanced APIs expose derivations, temporal behavior, provenance, frontiers,
reconciliation, worker details, and exact evidence. Compatibility APIs preserve
older names such as `pgreact_api.author_rule`, `run_rule`, and JSON declaration
helpers. They remain supported only according to their existing contract and
are not taught as the ordinary M32 workflow.
