# M18 canonical examples

`tests/m18-authoring.sql` runs all five examples in a dedicated clean database;
`tests/m18.sh` compares its complete output with
`tests/fixtures/m18/expected-small-transcript.txt`.

| Example | Required path | Limit recorded in fixture |
|---|---|---|
| Risk/fraud | suspicious-transfer constraint and review command | asynchronous consequences; no universal latency |
| Inventory | stock derivation and reorder aggregate | published dataset/resource envelope only |
| SLA/deadline | overdue lifecycle and escalation command | documented time and worker assumptions |
| Derived knowledge | positive recursion and stratified absence | no unstratified negation |
| Event-time windows | tumbling aggregate, out-of-order input, correction, finalization | fixed duration/lateness and supported watermark envelope |

The SQL is the executable data model, declaration, operation, exact-result, and
cleanup reference. It uses only application objects and `pgreact_api`/`pgreact`
public surfaces. The limits in the table are inherited from M17.

## Risk/fraud

`m18_risk.transfers` feeds a threshold view. The constraint exposes the current
match; the command writes one idempotent review row after public worker execution.
Source/action drift, failed work, and retry behavior use the inherited public
diagnostics. Cleanup removes both rules before the disposable schema is dropped.
It is not a fraud model and promises no synchronous rejection or universal SLA.

## Inventory

`products` supplies keys and `stock_lines` supplies units. One direct derivation
maintains current products; one `SUM(units)` aggregate derives the frozen reorder
threshold and is explained by public fact evidence. Deployment is bounded by
`max_iterations` and `max_facts`; overflow or drift fails without partial truth.
Cleanup removes program version 1. It does not reserve stock or optimize orders.

## SLA/deadline

Open tickets expose a database-time deadline; the command inserts one escalation
after the deadline lifecycle creates work. Worker failure remains durable and
diagnosable through the inherited lease/retry contract. Cleanup removes the rule.
Clock sampling is database-owned; this is not a wall-clock scheduler guarantee.

## Derived knowledge

Seed facts drive an `a -> b -> c -> b` positive cycle, while a separate negative
input derives only unblocked eligible keys in a higher stratum. The bounded run
must converge or fail atomically, and public explanation names all five rules.
Cleanup removes program version 1. Unstratified negation and unbounded proof
enumeration remain unsupported.

## Event-time windows

Out-of-order transfers enter one-hour tumbling `SUM` windows with 15 minutes of
allowed lateness. A value correction changes 11 to 14; watermark advancement
records correction history and finalizes the exact public window. Finalized late
input blocks progress until authoritative input is restored and reconciled.
Cleanup removes program version 1. Other window kinds and input beyond the
published retention/resource envelope are unsupported.

The frozen small-profile transcript is:

```text
risk/fraud|constraint+review-command|exact
inventory|derivation+aggregate|exact
sla/deadline|overdue+escalation|exact
derived-knowledge|positive-recursion+stratified-absence|exact
event-time-windows|out-of-order+correction+finalization|exact
cleanup|complete
```
