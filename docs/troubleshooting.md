# Troubleshooting

[How-to guides](how-to/index.md) · [Operations](operations.md)

Begin with the smallest observable difference between what you expected and what happened. In the **0.46.0 core profile**, a source condition, a current match, a work item, and an execution attempt are separate pieces of evidence. Looking at them in that order usually tells you whether the issue belongs to authoring, policy state, permissions, or runtime execution.

## Collect the first useful evidence

Run the following in the affected database, replacing the example name with your target. Keep the complete finding and error text when asking for help; a top-level `attention` or `error` alone loses the reason for the result.

```sql
SELECT current_database();
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;

SELECT pgreact.doctor();
SELECT pgreact_api.managed_status();
SELECT code, severity, blocking, target, message, hint, details
FROM pgreact.health
ORDER BY blocking DESC, severity, code, target;
SELECT pgreact.status('manual-review-required');
SELECT pgreact.explain('manual-review-required');
```

These are inspection calls. Avoid adding `pgreact.run()` to an initial diagnostic transcript unless you intend to coordinate new work. For an installation or package change, a read-only baseline is especially valuable because it lets you distinguish the pre-existing condition from the effect of the repair.

## Find the next step by symptom

| Symptom | Likely boundary to check | Next step |
| --- | --- | --- |
| Container is running but `psql` cannot connect | PostgreSQL may still be initializing. | Wait for TCP `pg_isready` to report accepting connections; inspect `docker compose logs postgres` if it does not. |
| Installed version differs from the tutorial | Package default or an existing persistent volume. | Check [release identity](reference/release-identity.md); initialization variables do not upgrade existing databases. |
| `doctor()` is not ready | Runtime, source, permission, or recovery finding. | Read the exact blocking finding and its hint. |
| No managed process or `configured = false` | Missing database entry, preload, or worker-role setup. | Follow [worker diagnosis](operations.md#diagnose-a-worker-or-backlog); restart after postmaster-setting changes. |
| Condition query returns no row | The source data does not currently satisfy the policy. | Query the condition directly and inspect applicability. |
| Active match but no task | Seeded bootstrap state, no consequence, or asynchronous work. | Check declaration kind, bootstrap policy, `pgreact.work`, and `pgreact.attempts`. |
| Work remains pending | Worker health, blocking findings, eligibility, or a growing backlog. | Inspect managed detail and the [backlog query](operations.md#inspect-a-backlog-or-failed-work). |
| `RETRY_WAIT` | A failed attempt is waiting for configured backoff. | Read its error, repair the cause, and let the due retry run. |
| `LEASED` work after a failure | The previous worker may still hold a lease. | Establish that it cannot execute, then [recover an expired lease](operations.md#recover-an-expired-lease). |
| A comparison is `partial` | An evidence or resource bound was reached. | Treat counts as incomplete; narrow the question or adjust the documented bound. There is no continuation token. |
| A decision is `AMBIGUOUS` | Multiple candidates share the lowest priority. | Inspect candidates and decide the intended priority policy. |
| A tracked decision is `NO_CANDIDATE` | All candidates for that subject disappeared. | Inspect source facts and handle the state in the application. |

## Resolve review and deployment findings

| Finding | Meaning | Response |
| --- | --- | --- |
| `M54_REVIEW_TOKEN_INVALID` | The value is malformed or is not a successful preview token. | Obtain it with `pgreact.review_token()` from a successful recognized preview. |
| `M54_REVIEW_TOKEN_MISMATCH` | Token and proposed declaration differ. | Use the exact reviewed declaration, including effective times. |
| `M54_REVIEW_TOKEN_STALE` | Source, declaration, work, or deployment state changed after review. | Preview and review again against the new state. |
| `M54_OLD_WORK_REQUIRED` | Executable old work needs an explicit disposition. | Choose `DRAIN_OLD` or `CANCEL_OLD` according to the intended change. |
| `M34_UNAUTHORIZED_TARGET` | The caller cannot inspect the target. | Use the authorized owner/operator/reader context. |
| `M34_UNAUTHORIZED_SOURCE` | The caller lacks required source access. | Grant the intended source access through the normal PostgreSQL role model. |
| `M34_RLS_UNSUPPORTED` | An evaluated source uses row-level security outside the supported boundary. | Use a supported source design; comparison does not return a redacted substitute. |

A returned finding is part of the API contract, not a reason to edit the private catalog into the state you wanted. Correct the declaration or prerequisite and repeat the public workflow. [Authoring](authoring.md), [Security](security.md), and [Changing policies safely](changing-policies.md) describe the appropriate changes.

## Repair drift and blocked coordination

`SOURCE_DRIFT` and `CONSEQUENCE_DRIFT` mean that the live source or function no longer matches the deployed identity. Restore the exact expected public object or deploy a reviewed replacement. If a consequence or dispatcher changes after work is queued, the affected item can fail or wait for retry while unrelated work continues, so inspect the item's full attempt history rather than assuming the whole worker stopped.

A managed process with `state = error` preserves the coordination cause in `detail`, including a structured blocked result. Resolve the reported source or barrier and use the owning public reconciliation procedure where required. Then verify that a later successful cycle clears the detail and that the intended application result appears. [Operations](operations.md#recover-after-drift-or-restore) and [Backup and restore](backup-restore.md) explain the recovery boundary.

## Gather a useful support report

Include the installed extension and PostgreSQL versions, the artifact or image identity, the affected public target name, the complete finding or SQLSTATE, managed status, and the relevant work and attempt rows. Describe the last source or policy change and the result you expected. Remove credentials and unrelated business data before sharing the report; preserve enough of the condition and declaration to reproduce the behavior in a disposable database.

A minimal reproduction built from [Your first rule](getting-started.md) is often more useful than a large private-catalog dump. If the problem depends on a specialized capability, include that capability's input bounds and versioned reference record from [History](history.md).
