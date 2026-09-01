# M44 explanation qualification contract

M44 is extension `0.41.0`. It gives users one documented way to read the
meaning and limits of the explanation results that pg-react already returns.
It does not add a new database function or change a result.

## Qualified operations

| Origin | Public call | Question | Result version |
|---|---|---|---:|
| Current outcome | `pgreact.explain(text, jsonb, jsonb)` | What does the current target say about this subject? | 14 |
| Why not | `pgreact.explain(text, jsonb, jsonb)` with `why_not` | Why is one expected result absent? | 26 |
| Causal path | `pgreact.explain(text, jsonb, jsonb)` with `causal_path` | Which supported facts lead to this result or work item? | 27 |
| Why changed | `pgreact.compare(declaration, target, jsonb)` with `why_changed` | Which supported causes explain a current comparison difference? | 25 |
| Retained causal path | `pgreact_api.read_evidence_snapshot(target, text, text)` | What exact M41 answer did M42 retain? | 28 containing 27 |

Identifier-first advanced explanation functions remain outside M44. Replay and
backtesting keep their existing why-changed behavior but are outside this
qualification.

## Shared vocabulary

M44 maps these words to fields that the installed operations already return.
It does not rename those fields.

| Term | Meaning |
|---|---|
| Origin | The operation that produced the answer. |
| Question identity | Public target, typed subject or result, root or comparison point, and snapshot identity when applicable. |
| Evidence point | The declaration, source definition, sampled time, frontier, revision, comparison side, or capture data used by the origin. |
| Complete | The origin checked every supported item within its limits. |
| Partial | A limit or incomplete evidence stopped the answer. The answer does not claim that omitted items do not exist. |
| Unavailable | The origin could not return a safe answer because required evidence or access was missing. |
| Unsupported | The question is outside the origin's supported model. |
| Boundary | The public reason that the origin could not follow or expose more evidence. |
| Finding | An origin-specific code with severity and a public message. |
| Limit | A deterministic bound reached during lookup, cause discovery, graph expansion, serialization, or payload construction. |
| Semantic digest | A digest of stable meaning. It excludes elapsed time and private identifiers. |
| Semantic cost | Reproducible work counters returned by the origin. |
| Elapsed time | A measured diagnostic value. It is not part of identity or a semantic digest. |
| Retained evidence | The exact complete M41 answer stored by M42. It is historical, not current truth. |

## Identity and equality

Public identity uses target kind, stable target name and version, typed subject
or result keys, root identity, comparison point and sides, declaration or
policy version, and snapshot identity where the origin exposes them.

Private UUIDs, transaction IDs, physical row order, and catalog identifiers do
not establish identity. Two answers are equivalent only when every evidence
input required by both origins is equal. A difference in time, frontier,
declaration, source definition, revision, comparison side, authorization
context, or snapshot capture makes the answers non-equivalent.

Each origin keeps its canonical array and graph order. Semantic output remains
stable across JSON object order, physical row order, supported plans, restart,
restore, adjacent upgrade, and supported standby promotion.

## Access and retention

Live answers use the originating operation's target, source, grant, and RLS
checks at the statement snapshot. M42 applies its existing owner-or-operator
rule to retained evidence. A later source grant or revocation does not change
access to a retained answer.

Missing, unauthorized, replaced, and removed targets fail closed. Denied
answers do not reveal a target, subject, root, result, source, graph shape,
count, value, digest, owner, retention time, or tombstone.

Live evidence can become partial or unavailable when current evidence expires,
is pruned, changes during the statement, or fails an authorization check. A
complete M42 answer remains historical until its snapshot is deleted. A deleted
snapshot exposes only the existing tombstone fields to an authorized reader.

## Limits and failure

Every origin keeps its installed limits and exact finding codes. A reached
limit produces `partial` and names the limit. The contract never upgrades a
weaker state, invents a cause, fills a missing field, or treats availability as
explanation completeness.

Current explanation and comparison calls remain read-only. M42 capture and
delete retain their existing explicit writes. M44 adds no durable state, write
path, option, response field, evaluator, wrapper, or explanation function.
