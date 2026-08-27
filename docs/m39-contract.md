# M39 qualification contract

M39 is a qualification release. It makes the existing M34–M38 simulation
functions one documented contract without adding a new evaluator, verb, result
format, or default option.

## Scope

The contract covers these public functions and their documented overloads:

- `pgreact.compare` and `pgreact.compare_results` for current and hypothetical
  comparison;
- `pgreact.replay` and `pgreact.replay_results` for a supplied snapshot and
  finite history;
- `pgreact.backtest` and `pgreact.backtest_results` for at most two policy
  versions over one supplied history.

The operation-specific contracts remain authoritative. M39 aligns their
qualification vocabulary and proves equivalence only when declarations,
targets, facts, logical times, frontiers, history, caller, options, and limits
are the same.

## Version and options

The qualification contract is version `1`. Existing result envelope versions
remain unchanged: M34 uses `21`, M35 uses `22`, M36 uses `23`, M37 uses `24`,
and M38 uses `25` when `why_changed` is requested.

M39 adds no option. Each function receives the options it already documents:
`evidence_limit`, the replay limits, and the opt-in boolean `why_changed`.
Missing options keep the earlier output. `why_changed: false` is identical to a
missing option. Null, malformed, or unknown options keep the originating
operation's existing finding and rejection behavior.

## Shared result rules

Every result records the fields that apply to its operation:

- target kind, target name, target version, declaration digest, and source
  identity;
- snapshot, change-set, replay, side, comparison, result, and explanation
  identities where those concepts exist;
- public payload digests, completeness state, reached bounds, findings, and
  semantic cost counters;
- a separately labeled `elapsed_ms` measurement, which is never part of a
  semantic digest.

`ready` or `complete` means the operation reached its requested bound and all
supported returned evidence is represented. `partial` reports the exact bound
that stopped the operation. `unavailable` and `unsupported` never claim that
an omitted cause or row did not exist.

## Canonical identity and digest

Qualification compares public identities, not storage identifiers. Canonical
identity uses target kind and name, typed business keys, result keys, replay
ordinals, side labels, and modeled evidence identities. Generated UUIDs,
transaction IDs, query plans, physical row order, and elapsed time are not
semantic identity.

Canonical serialization sorts object keys, uses the documented typed JSON
values, orders result rows by result set, replay ordinal, side, subject key, and
result key, and preserves the operation's explicit nulls. A digest is SHA-256
of that serialization. The same input and security context must therefore
produce the same semantic digest across repeated calls, plans, restart, restore,
adjacent upgrade, and supported standby promotion.

The following equivalences are qualified:

1. Current comparison equals comparison with an empty typed change set at the
   same authoritative snapshot.
2. A replay point equals a hypothetical comparison only when its snapshot,
   ordered change set, sampled time, and frontier describe the same state.
3. Same-policy backtesting has equal baseline and candidate sides and no
   invented difference.
4. An isolated production run over the same declaration, facts, logical time,
   and frontier has the same semantic results, lifecycle transitions, decisions,
   and would-be work as its simulation prediction.

## Findings, limits, and costs

The shared finding families are invalid input, incompatible target, stale input,
schema drift, unauthorized or RLS-protected data, ambiguity, cycles,
incomplete evidence, resource limits, and changed authoritative state. Each
function keeps its published M34, M35, M36, M37, or M38-prefixed code and its
required detail fields. The compatibility matrix records intentional
differences.

Nested work is counted once in the whole-call cost and remains visible in its
per-operation or per-side cost. Counters for rows, changes, replay steps,
differences, causes, support nodes, fan-out, depth, memory, temporary storage,
and would-be work are semantic. `elapsed_ms` is observational only.

## Security and no effect

The caller must be authorized for the target and every source needed by the
selected operation. The inherited fail-closed RLS boundary, safe security-
definer search path, and no-redaction behavior remain in force. Authorization
checks must not leak a target, source, subject, result, count, or evidence
value.

Every successful, rejected, canceled, timed-out, terminated, crashed, or
recovered simulation leaves source rows, pg-react state, lifecycle, work,
attempts, history, frontiers, evidence, and external effects unchanged.
Simulation never deploys a declaration, advances a frontier, executes a
consequence, or sends a message.
