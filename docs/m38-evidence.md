# M38 qualification evidence

The release gate is `tests/m38.sh complete`. Its static lane checks the SQL
composition, version metadata, inventories, finding registry, upgrade pair,
shell syntax, no-table boundary, and the absence of writes in `sql/m38.sql`.

Its packaged lane checks that missing and false `why_changed` preserve the M37
output, that changed backtest rows contain bounded explanations, that unchanged
rows contain no invented cause, and that the relational result carries the same
evidence. It also checks the M38 option type and the no-mutation checksum.

The complete profile starts from `0.34.0`, applies the adjacent migration, and
checks the upgraded public function. The inherited M37 gate runs against the
published `v0.34.0` artifact in the release workflow.

The reference fixture covers a changed source value, an `ADDED` or `REMOVED`
shape through the shared difference model, a policy output change, an
`UNCHANGED` self-comparison, a bounded result, and an invalid option. The
benchmark records three workload shapes and their declared budgets.
