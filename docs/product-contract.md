# Product contract

[Reference](reference/index.md) · [Concepts](concepts.md)

The **pg-react 0.46.0 core profile** keeps PostgreSQL authoritative for application facts, declarations, policy lifecycle, work, attempts, and explanations. PostgreSQL-managed workers are the normal runtime. They observe committed data and execute eligible durable work asynchronously, while application developers use typed declarations and stable names to describe and inspect the intended behavior.

The ordinary authoring contract is to construct a declaration, validate it, compare a replacement when appropriate, preview the operation, review the result, deploy, and inspect. Review provides evidence rather than authorization: deployment rechecks ownership, source definitions, declaration identity, work state, and safety barriers. Private schemas and identifiers are not the ordinary application interface.

Database-local consequences use PostgreSQL transaction boundaries. Delivery outside the database is at least once and requires consumer deduplication. Comparison and explanation provide bounded evidence; a partial answer must remain identified as partial. The [known limitations](known-limitations.md) describe the unsupported cases, and the [SQL reference](api-reference.md) describes the public call shapes.

R0 qualifies pg_trickle `0.108.0` on PostgreSQL `18.3` with trigger CDC, explicit refresh coordination, and the independent pg_trickle scheduler disabled. Stable Graph V1.2 and Delta V1.1 exist upstream but are unused by this profile. Its optional MDM adapter remains disabled; the separately published adapter 0.50.0 is a synthetic demo with `release_qualified: false`, not a real-workload support claim. [Versions and release identity](reference/release-identity.md) records how those artifacts differ.
