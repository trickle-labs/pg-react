# M28 compatibility inventory

| Area | M28 contract |
| --- | --- |
| Extension | `0.25.0`; direct upgrade from `0.24.0` |
| Ordinary workflow | define, validate, preview, deploy, run, status/explain |
| Declaration | API version `1`, stable kind/name, named JSONB spec |
| Target | names-first kind/name with optional historical version |
| Envelope | contract version `16`, stable summary/findings/evidence/diagnostics fields |
| Existing APIs | retained unchanged as advanced or compatibility surfaces |
| Security | no new `PUBLIC` access; existing configure_roles grants façade access |
| Evaluation | existing specialized runtime remains authoritative |
| Next milestone | M29 — Policy-set gating |

M28 does not add a proprietary language, policy-set gating, simulation,
replay, backtesting, automatic repair, or generic arbitrary-SQL execution.
