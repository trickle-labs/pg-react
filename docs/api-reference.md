# API Reference

This is the current pg-react `0.43.0` reference. Choose a surface by the job
it performs, not by a milestone number.

## Ordinary

`pgreact.rule(...)`, `pgreact.decision(...)`, `pgreact.validate(declaration)`,
`pgreact.preview(declaration, options)`, `pgreact.deploy(declaration,
preconditions)`, `pgreact.deploy(declaration, review_token, preconditions)`,
`pgreact.review_token(preview_result)`, `pgreact.status(name)`,
`pgreact.explain(name)`, `pgreact.run()`, `pgreact.export(name, kind, version)`,
and `pgreact.import(document, preconditions)` are the normal application path.

`review_token` is opaque reviewed-plan evidence. It is not a password, bearer
credential, or authorization grant. The JSON-preconditions deployment overload
remains supported.

## Advanced and administrative

Derived facts, temporal/effective-dated policies, provenance, simulation,
backtesting, evidence snapshots, and semantic analysis are advanced surfaces.
Role configuration, pause/resume, worker leases, repair, and recovery are
administrative surfaces. Existing compatibility replacements remain installed
but are not the preferred ordinary replacement path.

The [machine-readable API inventory](api-inventory.json) is checked by CI.
