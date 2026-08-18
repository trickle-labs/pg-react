# M33 final checklist

> [!NOTE]
> Historical unchecked `0.30.0` qualification checklist. It is retained as
> evidence and does not block the current M34 / `0.31.0` v1 boundary by
> itself. See [`history.md`](history.md).

- [ ] Installed-reality API inventory equals the frozen JSON inventory.
- [ ] Finding registry and result-envelope shape are stable.
- [ ] Adjacent upgrades and populated direct `0.26.0` upgrade preserve state.
- [ ] Restart, restore, logical restore, PITR, and supported promotion pass.
- [ ] Public-surface security review has no blocker.
- [ ] Every bounded subsystem has a documented safe limit.
- [ ] Public diagnostics and runbooks cover every supported failure mode.
- [ ] Packaged documentation examples execute successfully.
- [ ] Five-person usability evidence meets the thresholds.
- [ ] Two controlled pilots complete with no P0/P1 finding.
- [ ] No unresolved P0 or P1 defect remains.
- [ ] Exact `0.30.0` artifacts can produce `1.0.0-rc.1`.

The checklist is intentionally separate from the release notes so a candidate
can be requalified without rewriting the user-facing summary.
