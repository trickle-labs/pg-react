# pg-react

**Turn changing PostgreSQL data into decisions and durable work you can explain.**

An order becomes risky, a review becomes overdue, or a customer becomes eligible for a different policy. Your application already knows these facts in PostgreSQL. pg-react lets you describe the condition with SQL, give each result a stable business identity, and keep the resulting decisions, work, retries, and explanations in the same database. You can ask what is true now, what happened when it changed, and what a proposed policy would do before you deploy it.

The project is **pg-react**; the PostgreSQL extension is `pg_react`, and its main SQL interface is `pgreact`. You do not need a separate rule language to get started. A condition view, a typed declaration, and a few inspection queries are enough for your first useful rule.

## Start here

Follow [Your first rule](docs/getting-started.md) to bring up a disposable database, create a review rule, change an order, and watch a database function create a review task. The tutorial includes every prerequisite, the complete SQL, expected results, and cleanup. It uses the qualified core release **0.46.0**, PostgreSQL **18.3**, and pg_trickle **0.108.0** on Linux **amd64**.

If you want to prepare that environment now, run these commands in a new checkout:

```bash
git clone https://github.com/trickle-labs/pg-react.git
cd pg-react
export COMPOSE_PROJECT_NAME=pgreact-learning
export PG_REACT_IMAGE=ghcr.io/trickle-labs/pg-react:v0.46.0
export PG_REACT_INIT_VERSION=0.46.0
docker compose pull postgres
docker compose up -d --wait --no-build postgres
for attempt in $(seq 1 60); do
    docker compose exec -T postgres pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1 && break
    sleep 1
done
docker compose exec -T postgres pg_isready -h 127.0.0.1 -U postgres -d postgres && \
    docker compose exec postgres psql -X -U postgres -d postgres
```

Docker Engine or Docker Desktop with Compose is required. The readiness check waits up to a minute for the final PostgreSQL server to accept TCP connections; if it does not, inspect `docker compose logs postgres` before continuing. The Compose service initializes the extensions and runs the managed worker; its password and superuser connection are for this local lesson. At the `psql` prompt, continue with [Verify your starting point](docs/getting-started.md#2-verify-your-starting-point). For an existing PostgreSQL deployment, use the [installation guide](docs/installation.md) instead.

## A first rule

A rule connects a named condition to its semantic key: the business identity that lets pg-react recognize the same subject across changes. In the tutorial, the condition is a view of high-value risky orders and the key is `order_id`. After creating that view, this declaration describes a constraint that records its matches:

```sql
SELECT pgreact.validate(pgreact.rule(
    name         => 'manual-review-required',
    condition    => 'rule_def.high_value_risky_order'::regclass,
    semantic_key => 'order_id'::name
));
```

Validation checks the declaration without deploying it. You then preview the proposed change and deploy the reviewed declaration. To create work when a match activates, changes, or deactivates, make it a `COMMAND` rule and attach typed PostgreSQL functions. The tutorial walks through that complete path, including the difference between coordinating a rule and waiting for its consequence to finish.

## Choose a path

The documentation follows [Diátaxis](https://diataxis.fr/), so you can choose the kind of help you need without reading everything in order.

| Your goal | Where to go |
| --- | --- |
| Learn by building something that works | [Tutorials](docs/tutorials/index.md): your first rule, then an order-review policy with decisions and retries. |
| Complete a specific task | [How-to guides](docs/how-to/index.md): author, compare, deploy, secure, operate, recover, and upgrade. |
| Look up a signature, default, setting, or limit | [Reference](docs/reference/index.md): SQL API, configuration, support boundaries, and release identity. |
| Understand the behavior and make design choices | [Explanation](docs/explanation/index.md): lifecycle, identity, consistency, delivery, and advanced capabilities. |

The [documentation home](docs/index.md) connects those paths into a progression. Once the first rule feels familiar, the [order-review tutorial](docs/order-review-tutorial.md) adds routing decisions, policy applicability, lifecycle changes, failure recovery, and a side-effect-free comparison. The [advanced learning guide](docs/explanation/advanced-use.md) helps you choose the next capability for your actual problem.

## What pg-react provides

Rules retain current matches, activation generations, watched changes, and durable consequence work. Decisions select among relational candidates and expose a winner, ambiguity, or no-candidate result. Policy sets bring related declarations together with explicit applicability, and comparison lets you examine the current and proposed outcomes over the same facts before making a change. These features share a PostgreSQL-native inspection model, so operational questions can be answered with public views and stable names.

There is room to grow beyond ordinary rules. Installed advanced interfaces include derived facts, bounded recursion, temporal policies, shared conditions, parameter families, replay, backtesting, causal explanations, and retained evidence. Each has its own supported inputs and resource limits; [advanced use](docs/explanation/advanced-use.md) explains how to approach them without assuming that one feature's guarantees apply to another.

## Guarantees and boundaries

PostgreSQL remains authoritative for application facts and pg-react state. A database-local consequence and its recorded execution participate in PostgreSQL transactions, while delivery to an external system is at least once and requires consumer deduplication. Managed workers run asynchronously, one per configured database, so a successful application write does not mean that every consequence has already completed. pg-react is intended for durable policy evaluation and work; synchronous write rejection, distributed transactions, and general workflow orchestration are outside its contract.

The public learning path is pinned to the qualified **0.46.0 core release**. This repository also contains **0.46.2 core maintenance SQL**, a distinct Rust package version, and separately versioned MDM integration work. Those numbers do not describe the same release. Read [Versions and release identity](docs/reference/release-identity.md) before installing from source or choosing an upgrade, and use the [support matrix](docs/support-matrix.md) to check your environment. The R0 profile keeps pg_trickle's scheduler off and retains explicit pg-react coordination.

## Documentation

Start with [Troubleshooting](docs/troubleshooting.md) when the result differs from your expectation, or [Operations](docs/operations.md) when work stops progressing. The [glossary](GLOSSARY.md) defines the vocabulary used throughout the guides. Release notes, qualification records, and earlier design decisions remain available through [History](docs/history.md); the [roadmap](ROADMAP.md) describes work beyond the current core release.

## Naming

Use `pg-react` for the project, `pg_react` for the installed extension, and `pgreact` or `pgreact_api` for the documented public SQL surfaces.

## License

Licensed under the [Apache License 2.0](LICENSE).
