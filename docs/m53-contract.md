# Policy-set packaging contract

Extension `0.42.0` treats a policy set as one named, immutable version. A
package can contain rules, decisions, shared conditions, parameter families,
the rows that make it apply, and typed dependency edges.

The package digest is calculated from the canonical declaration, applicability,
effective period, dependency graph, and package format version. It does not
include PostgreSQL OIDs, private UUIDs, physical row order, elapsed time,
source rows, evidence rows, or generated object names.

## Public workflow

1. Build a typed declaration with `pgreact.policy_set()`.
2. Call `pgreact.validate()` or `pgreact.preview()` and save the returned plan
   digest.
3. Review the canonical `ADD`, `KEEP`, `REPLACE`, `ADOPT`, and `REMOVE`
   actions.
4. Call `pgreact.deploy()` with the plan digest as a precondition.
5. Use `pgreact.status()`, `pgreact.policy_set_contents`, and
   `pgreact.policy_set_dependencies` to inspect the installed package.
6. Export the package before moving it to another database. Import checks the
   canonical digest before deployment.

Deploy and remove are atomic. A failed child deployment, stale preview,
dependency error, ownership error, or limit violation leaves the package and
its existing runtime untouched.

`ADOPT` is explicit: include the exact child identity in the `adopt` precondition
before taking an already-deployed child into package ownership. A child already
owned by another package cannot be adopted across package boundaries.

## Limits

| Item | Limit |
|---|---:|
| Member declarations | 64 |
| Support declarations | 64 |
| Dependency edges | 256 |
| Canonical JSON | 1 MiB |

The existing policy-set declaration and the existing validation, preview,
deploy, status, remove, export, and import entry points remain compatible.
Older policy-set declarations are accepted as reference-only packages; a
complete package must include the typed child declarations needed for replay.
