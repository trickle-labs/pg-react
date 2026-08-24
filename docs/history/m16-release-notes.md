# pg-react 0.13.0 — richer stratified aggregation

M16 adds one typed `COUNT(expression)`, `SUM`, `MIN`, or `MAX` dependency to a
stratified rule while retaining existing `COUNT(*)` declarations. Each uses one
named input column, PostgreSQL-native value, null, comparison, collation, and
overflow semantics within the published type matrix.

Aggregate evidence and explanation now report the function, value expression,
types, exact value, comparison, threshold, lower frontier, and truth result.
Changes that do not cross a comparison update evidence without a false support
or lifecycle transition. The supported direct upgrade is `0.12.0 -> 0.13.0`.

The release publishes `pg-react-v0.13.0-linux-amd64.tar.gz`, its SHA-256
manifest, and immutable `linux/amd64` OCI digest after `tests/m16.sh` passes.
