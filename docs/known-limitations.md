# Known limitations

[Reference](reference/index.md) · [Support matrix](support-matrix.md)

These boundaries apply to the qualified **pg-react 0.46.0 core profile**. They are most useful during design: knowing which guarantee belongs to the rule engine, the database, or your application helps you choose the correct integration before there is production work to recover.

## Execution and delivery

Managed evaluation is asynchronous, so a successful application write is not proof that its consequence has completed. Database-local effects use PostgreSQL transactions, but delivery beyond PostgreSQL is at least once and requires stable consumer deduplication. The core contract does not provide synchronous source-write rejection, cross-system atomic commits, a global order across independent policies, or a general workflow engine.

A command-rule replacement with eligible old work requires an explicit drain-or-cancel choice. The runtime cannot infer whether an already-created review task or delivery still makes sense under your new policy. Preserve that decision in the replacement plan and inspect the resulting work state.

## Source and identity support

The ordinary rule codec and ordinary rule comparison require one non-null unique `bigint` semantic key. Specialized advanced typed-key authoring has a broader boundary, but it does not automatically expand the ordinary constructor or comparison. RLS-backed evaluated sources are outside the qualified boundary and are rejected rather than evaluated through an assumed redaction policy.

Private `pgreact_internal` and `pgreact_runtime` schemas and internal identifiers are not a supported application interface. Public names, typed declarations, and documented views provide the ordinary integration surface. Editing private rows can bypass the invariants that validation, deployment, and recovery are intended to protect.

## Evidence and simulation

Comparison and explanation are bounded. A `partial` answer does not prove that the omitted remainder is empty, and relational result functions do not provide a hidden continuation path. Replay and backtesting require a finite history supplied by the caller; they do not capture missing history or create durable simulation jobs.

Comparison's fan-out, reevaluation, cascade, memory, and temporary-storage fields are not all populated as supported measurements. The selected-state checksum is narrower than the complete database or external delivery state. Use the [comparison guide](changing-policies.md) and [limits](limits.md) to interpret those fields within their actual scope.

## Qualification scope

The support tuple and workload envelope are explicit. A benchmark result from the pinned runner is not a general throughput promise, and a separately qualified adapter does not widen the core release's support matrix. Read [Versions and release identity](reference/release-identity.md) when a container, Rust package, core SQL file, and integration tag show different numbers.
