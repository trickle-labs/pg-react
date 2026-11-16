# pg-react documentation

Welcome to pg-react. If your data already lives in PostgreSQL, you can use SQL to describe when a policy applies and let pg-react keep track of what that means over time. These guides take you from one working rule to a system you can change, inspect, and operate with confidence. You need basic SQL and familiarity with tables and views; you can learn the pg-react vocabulary as you go.

The main learning path uses the qualified **pg-react 0.46.0 core release**, PostgreSQL **18.3**, and pg_trickle **0.108.0**. Source-tree maintenance versions and the optional MDM adapter have separate identities. [Versions and release identity](reference/release-identity.md) explains the distinction, and the [support matrix](support-matrix.md) records the qualified environment.

## Choose the help you need

The documentation uses [Diátaxis](https://diataxis.fr/): practical lessons for learning, task guides for doing, reference for looking things up, and explanation for understanding why the system behaves as it does.

| I want to… | Start here | What you will find |
| --- | --- | --- |
| Build my first working example | [Tutorials](tutorials/index.md) | Guided lessons with complete setup, visible checkpoints, and a next step. |
| Solve a particular problem | [How-to guides](how-to/index.md) | Focused procedures for authoring, policy changes, security, operations, and recovery. |
| Check the exact contract | [Reference](reference/index.md) | Function signatures, public views, settings, limits, and compatibility. |
| Understand a design choice | [Explanation](explanation/index.md) | Identity, lifecycle, transactional boundaries, and a route into advanced features. |

## A path from beginner to advanced user

**First, make one rule work.** Follow [Your first rule](getting-started.md) in a disposable Compose environment. You will define a condition, deploy a command rule, change an order, and inspect the resulting task. Read [Concepts](concepts.md) alongside the lesson when terms such as generation, revision, or source frontier need a fuller explanation.

**Next, connect the pieces.** The [order-review tutorial](order-review-tutorial.md) builds on that foundation with decisions, policy applicability, retries, and comparison. Its [runnable package](../showcase/order-review/README.md) includes scripts and an exact expected transcript, so you can revisit the scenario without copying a long page of SQL. When you start adapting it, use [Authoring rules and policies](authoring.md) and [Changing policies safely](changing-policies.md).

**Then, make the system operable.** Work through [Security](security.md), [Operations](operations.md), and [Backup and restore](backup-restore.md) before depending on background work. Learn to distinguish current matches, queued work, and execution attempts, and rehearse recovery using a disposable copy of your database. [Troubleshooting](troubleshooting.md) connects symptoms and finding codes to the appropriate procedure.

**Finally, add only the advanced capability your problem needs.** [Advanced use](explanation/advanced-use.md) connects recurring design problems to derived facts, temporal policies, shared conditions, simulation, and explanation. Keep the [SQL reference](api-reference.md), [configuration reference](reference/configuration.md), and [limits](limits.md) nearby as you move beyond the ordinary declaration path.

## Already running pg-react?

For a failing or delayed work item, begin with [Operations](operations.md#inspect-a-backlog-or-failed-work). To understand an unexpected result, use [Explain an outcome](explaining-outcomes.md). For a policy replacement, use [Changing policies safely](changing-policies.md); for a package or extension update, use [Upgrade](upgrade.md). Those are different changes with different procedures.

## Project and release records

The [glossary](../GLOSSARY.md) is a vocabulary lookup. The [product contract](product-contract.md), [known limitations](known-limitations.md), [compatibility policy](compatibility.md), and [current release manifest](current-release.json) define the public boundary. [History](history.md) preserves older milestone documents and qualification evidence. They remain useful records, but the guides linked from this page are the starting point for current core users.
