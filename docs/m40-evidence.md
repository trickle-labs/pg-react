# M40 qualification evidence

The release gate is `tests/m40.sh complete`. Its static lane checks the 0.37.0
metadata, SQL composition, contract, inventories, examples, benchmark,
compatibility notes, migration, release notes, checklist, shell syntax, and
no-write boundary.

Its packaged lane runs the inherited M0 through M39 fixtures and a conformance
fixture for missing rule input, present rule results, decision candidates,
policy eligibility, invalid requests, unsupported targets, authorization, RLS,
stale frontiers, deterministic ordering, resource bounds, and unchanged
authoritative checksums.

The field-shaped qualification record uses a financial-exception workload. An order expected
to enter manual review is absent from the deployed rule result. The operator
records the manual source-view lookup, match inspection, refresh status, and
the exact public evidence available to the caller. The M40 answer replaces
those private-table diagnosis steps with one public `pgreact.explain` call.
The same corpus includes an access-drift case and an order-routing case so the
review covers applicability and candidate selection.

The complete profile installs a populated `0.36.0` database, applies the
adjacent update, restores the pre-update backup, and checks the public
explanation surface after restore. Wall-clock time is separate from semantic
counters.
