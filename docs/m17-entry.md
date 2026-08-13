# M17 entry record and frozen reference

M17 starts from immutable `v0.13.0` at commit
`7b647679f89576bc0a831f39ea1f42b7ff61ceac` (`Implement M16 richer
stratified aggregation`). The local and public tags resolve to that exact
commit. The public records below were reverified on 2026-08-13; both runs are
completed successes at that commit, and the release is non-draft,
non-prerelease, published at `2026-08-13T12:59:10Z`.

- successful branch CI: [31699689382](https://github.com/trickle-labs/pg-react/actions/runs/31699689382);
- successful release workflow: [31699725097](https://github.com/trickle-labs/pg-react/actions/runs/31699725097);
- release: <https://github.com/trickle-labs/pg-react/releases/tag/v0.13.0>;
- archive: `pg-react-v0.13.0-linux-amd64.tar.gz`;
- archive SHA-256: `b833a920467507b2476e5b3c70388ecabbcde109927b17c304a3de2d8e0772ac`;
- OCI image: `ghcr.io/trickle-labs/pg-react:v0.13.0@sha256:f5d55947bdd77b7f88f2ee7b1dd03f980aa9d198587b0faf1d1317ec30250c06`.

GitHub's archive asset digest and the published checksum manifest agree on the
archive SHA-256; that same manifest records the OCI identity above.

The release workflow ran `tests/m16.sh pg-react:v0.13.0`. Its populated
upgrade fixture created `0.12.0`, ran `tests/m16-upgrade.sql`, upgraded directly
to `0.13.0`, and required exact facts, supports, aggregate evidence, and typed
metadata before returning `M16 populated 0.12.0 to 0.13.0 upgrade gate passed`.
The same gate covered the inherited suite, the complete aggregate/type matrix,
replacement, logical restore, crash restart, and physical recovery. These
identities and results are the immutable predecessor evidence for M17.

## Frozen declaration

The reference program is `m17.reference@1`. It has `max_iterations = 8` and
`max_facts = 64`, one finite `group_source(account_id bigint)`, and one finite
`item_source(item_id bigint, account_id bigint, amount numeric, occurred_at
timestamptz)`. Its derived keys are `(account_id bigint, window_ordinal bigint)`.

Every rule has `definition = m17_reference.group_source`, `key = account_id`,
`version = 1`, and this exact window member inside `aggregate_input`:

```json
{"event_time":"occurred_at","duration":"PT1H","allowed_lateness":"PT15M"}
```

The preview's normalized member is exactly:

```json
{"alignment":"UTC_EPOCH","allowed_lateness_us":900000000,"duration_us":3600000000,"event_time":"occurred_at"}
```

The five rules, in canonical rule-name order, are:

| Rule | Target | Function | Expression | Comparison |
|---|---|---|---|---|
| `m17.count_all` | `m17_reference.count_all_alert` | `COUNT(*)` | `*` | `>= 2` |
| `m17.count_amount` | `m17_reference.count_amount_alert` | `COUNT` | `amount` | `>= 2` |
| `m17.max_amount` | `m17_reference.max_amount_alert` | `MAX` | `amount` | `>= 8` |
| `m17.min_amount` | `m17_reference.min_amount_alert` | `MIN` | `amount` | `< 5` |
| `m17.sum_amount` | `m17_reference.sum_amount_alert` | `SUM` | `amount` | `>= 10` |

There are no other declaration members. An absent `window` member remains an
unwindowed M16 declaration byte-for-byte. A windowed rule has exactly one
window and one inherited aggregate dependency; changing it requires immutable
program replacement.

M17 adds no aggregate or value type. The immutable M16 type oracle is
`v0.13.0:tests/m16-matrix.sql` (SHA-256
`8aa29f2dbe9bfd2fffdf4dce367377750c8b576b7f14f58f47926f2ab98ec8af`).
Adding one common `occurred_at = '1970-01-01T00:30:00Z'` to that fixture must
return every tagged expected value, null, `NaN`, infinity, type, collation,
truth, fact, and support unchanged except that every group key appends ordinal
`0`; every evidence row also adds the reference window fields and F1 correction
identity. This is the exact windowed oracle for every M16-supported aggregate
type. The five rules below add `COUNT(*)` and the multi-frontier behavior.

Durations accept only an exact integral number of PostgreSQL microseconds.
Duration is in `[1, 9223372036854775807]`; allowed lateness is in
`[0, 9223372036854775807]`. Years and months are invalid because they are not
fixed durations. Preview renders integer microseconds, independent of
`IntervalStyle`. Event time and watermark targets must be direct, finite,
non-null `timestamptz` values. Boundary arithmetic that cannot produce finite
`timestamptz` bounds or a signed `bigint` ordinal fails without mutation.

## Window identity

Let `t` be the event timestamp represented as exact microseconds from
`1970-01-01 00:00:00+00`, and `d` be `duration_us`. The signed ordinal is
`floor(t / d)`, including for negative `t`. Start is `epoch + ordinal * d` and
end is `start + d`; the interval is `[start, end)`. The public key appends the
ordinal to the declared group tuple, so account `7`, ordinal `-1` renders
exactly as `[7,-1]`. Identity and ordering use M15 codec-v2 bytes, never JSON
lexical order.

For the reference duration, the assignments are exact in every session time
zone:

```text
event_time|ordinal|window
1969-12-31T23:59:59.999999Z|-1|[1969-12-31T23:00:00.000000Z,1970-01-01T00:00:00.000000Z)
1970-01-01T00:00:00.000000Z|0|[1970-01-01T00:00:00.000000Z,1970-01-01T01:00:00.000000Z)
1970-01-01T00:00:00.000001Z|0|[1970-01-01T00:00:00.000000Z,1970-01-01T01:00:00.000000Z)
1970-01-01T01:00:00.000000Z|1|[1970-01-01T01:00:00.000000Z,1970-01-01T02:00:00.000000Z)
1970-01-01T02:00:00.000000Z|2|[1970-01-01T02:00:00.000000Z,1970-01-01T03:00:00.000000Z)
```

Only touched windows exist. Moving the last row out of `[7,-1]` retains its
empty states (`COUNT = 0`; other aggregates and their comparison truth are SQL
null) until finalization. No other empty window is synthesized.

## Frozen input schedule

`F1` through `F11` are committed lower-input frontiers. Operations at one
frontier are one transaction.

| Frontier | Operation |
|---:|---|
| F1 | insert `(1,7,4,'1969-12-31T23:59:59.999999Z')`, `(2,7,6,'1970-01-01T00:00:00Z')`, `(3,7,5,'1970-01-01T00:00:00.000001Z')` |
| F2 | out-of-order insert `(4,7,10,'1970-01-01T00:00:00Z')` |
| F3 | move item 1 to `1970-01-01T01:00:00Z` |
| F4 | change item 4 amount to `8` and move it to `1970-01-01T01:00:00Z` |
| F5 | delete item 2 |
| F6 | change item 3 amount from `5` to `12`; replay F6 once |
| F7 | after complete watermark `01:15Z`, insert correctably late `(5,7,1,'1970-01-01T01:30:00Z')` |
| F8 | insert on-time `(6,7,10,'1970-01-01T02:00:00Z')` |
| F9 | insert valid null expression `(7,7,NULL,'1970-01-01T02:30:00Z')` |
| F10 | after complete watermark `03:15Z`, insert too-late `(8,7,1,'1970-01-01T01:45:00Z')` |
| F11 | delete item 8 and reconcile |

## Exact aggregate and correction output

In the output below, value/truth positions are always
`count_all,count_amount,max_amount,min_amount,sum_amount`; `null` is SQL null.
Each row creates exactly five corrections in canonical rule-name order. A move
creates the old-window row before the new-window row. The durable correction
identity is exactly
`program@version/rule@version/public-window-key/lower-frontier`, for example
`m17.reference@1/m17.sum_amount@1/[7,1]/F7`. Ordering is codec-v2 window key,
then lower frontier, then rule name. The before state is the preceding row for
that key, or absent.

```text
window_key|frontier|values|truths
[7,-1]|F1|1,1,4,4,4|false,false,false,true,false
[7,-1]|F3|0,0,null,null,null|false,false,null,null,null
[7,0]|F1|2,2,6,5,11|true,true,false,false,true
[7,0]|F2|3,3,10,5,21|true,true,true,false,true
[7,0]|F4|2,2,6,5,11|true,true,false,false,true
[7,0]|F5|1,1,5,5,5|false,false,false,false,false
[7,0]|F6|1,1,12,12,12|false,false,true,false,true
[7,1]|F3|1,1,4,4,4|false,false,false,true,false
[7,1]|F4|2,2,8,4,12|true,true,true,true,true
[7,1]|F7|3,3,8,1,13|true,true,true,true,true
[7,2]|F8|1,1,10,10,10|false,false,true,false,true
[7,2]|F9|2,1,10,10,10|true,false,true,false,true
```

Replaying F6, watermark work, the rejected F10 maintenance, and the net-zero
F10-to-F11 repair add no correction. A truth-preserving row still updates exact
evidence and has a correction, but retains its support identity and emits no
lifecycle event. F9 therefore has five corrections even though only
`COUNT(*)` changes truth.

After F9, and again after F11 reconciliation, current facts are exactly:

```text
m17_reference.count_all_alert|[7,1]|G1
m17_reference.count_all_alert|[7,2]|G1
m17_reference.count_amount_alert|[7,1]|G1
m17_reference.max_amount_alert|[7,0]|G2
m17_reference.max_amount_alert|[7,1]|G1
m17_reference.max_amount_alert|[7,2]|G1
m17_reference.min_amount_alert|[7,1]|G1
m17_reference.sum_amount_alert|[7,0]|G2
m17_reference.sum_amount_alert|[7,1]|G1
m17_reference.sum_amount_alert|[7,2]|G1
```

The suffix is the stable support generation. Current evidence also retains the
ten false/null window-rule states not listed as facts. The exact lifecycle
history is:

```text
F1|[7,-1]|m17.min_amount|ACTIVATE|G1
F1|[7,0]|m17.count_all|ACTIVATE|G1
F1|[7,0]|m17.count_amount|ACTIVATE|G1
F1|[7,0]|m17.sum_amount|ACTIVATE|G1
F2|[7,0]|m17.max_amount|ACTIVATE|G1
F3|[7,-1]|m17.min_amount|DEACTIVATE|G1
F3|[7,1]|m17.min_amount|ACTIVATE|G1
F4|[7,0]|m17.max_amount|DEACTIVATE|G1
F4|[7,1]|m17.count_all|ACTIVATE|G1
F4|[7,1]|m17.count_amount|ACTIVATE|G1
F4|[7,1]|m17.max_amount|ACTIVATE|G1
F4|[7,1]|m17.sum_amount|ACTIVATE|G1
F5|[7,0]|m17.count_all|DEACTIVATE|G1
F5|[7,0]|m17.count_amount|DEACTIVATE|G1
F5|[7,0]|m17.sum_amount|DEACTIVATE|G1
F6|[7,0]|m17.max_amount|ACTIVATE|G2
F6|[7,0]|m17.sum_amount|ACTIVATE|G2
F8|[7,2]|m17.max_amount|ACTIVATE|G1
F8|[7,2]|m17.sum_amount|ACTIVATE|G1
F9|[7,2]|m17.count_all|ACTIVATE|G1
```

## Watermark and finalization contract

A watermark belongs to the logical timed input
`(program_name, schema-qualified relation, event_time column)`. The five
reference rules therefore share one requested/complete pair. Immutable program
replacement preserves that pair when the logical timed input is unchanged.

The public target operation is frozen as
`request_watermark(program_name text, input_relation text,
event_time_column name, target timestamptz)`. Only the configured operator may
call it; readers may inspect status and authors cannot advance it. The relation
must be schema-qualified and the target finite. One `READ COMMITTED`
transaction locks program then timed input, rejects a target below the current
requested value, treats equality as a no-op, and persists a greater requested
value without changing complete.

The coordinator alone advances complete. One transaction takes the inherited
global run lock, then program, timed input, lower-frontier, lateness-boundary,
codec-v2 window-key, correction, and downstream-agenda locks in that order. It
finalizes the earliest complete lateness boundary and commits complete exactly
to that boundary. If no materialized boundary remains before the target, it
commits complete to the target. `pg_react.batch_size` bounds window identities
per batch (`1..1000`, default `32`); a batch never splits identities sharing one
lateness boundary. If the earliest boundary alone exceeds the bound, the batch
fails without mutation and names the required minimum.

The reference sets `batch_size = 1` and returns:

```text
operation|requested|complete|finalized|status
initial|-infinity|-infinity|empty|complete
request 01:15|1970-01-01T01:15:00.000000Z|-infinity|empty|pending
advance|1970-01-01T01:15:00.000000Z|1970-01-01T00:15:00.000000Z|[7,-1]|pending
advance|1970-01-01T01:15:00.000000Z|1970-01-01T01:15:00.000000Z|[7,0]|complete
repeat 01:15|1970-01-01T01:15:00.000000Z|1970-01-01T01:15:00.000000Z|empty|complete
backward 01:00|1970-01-01T01:15:00.000000Z|1970-01-01T01:15:00.000000Z|empty|M17_WATERMARK_BACKWARD
request 03:15|1970-01-01T03:15:00.000000Z|1970-01-01T01:15:00.000000Z|empty|pending
advance|1970-01-01T03:15:00.000000Z|1970-01-01T02:15:00.000000Z|[7,1]|pending
injected failure|1970-01-01T03:15:00.000000Z|1970-01-01T02:15:00.000000Z|empty|failed
repeat 03:15|1970-01-01T03:15:00.000000Z|1970-01-01T02:15:00.000000Z|empty|pending
restart and advance|1970-01-01T03:15:00.000000Z|1970-01-01T03:15:00.000000Z|[7,2]|complete
```

Finalization identities are `[7,-1]@00:15Z`, `[7,0]@01:15Z`,
`[7,1]@02:15Z`, and `[7,2]@03:15Z`, each recorded once. Concurrent requests
serialize on the timed input: equal targets coalesce, greater targets leave the
greatest requested value, and a target that is backward after lock acquisition
fails. A standby returns SQLSTATE `25006` and changes neither value.

## Too-late policy and diagnostics

A window accepts a committed lower delta exactly while
`complete_watermark < window_end + allowed_lateness`. Equality is final. The
existing architecture does not intercept arbitrary authoritative DML: the
source F10 commit succeeds, but the next maintenance pass detects the finalized
window before changing derived state. It records one durable diagnostic, sets a
program `LATE_INPUT` claim barrier, leaves program lower frontier F9 and all
facts, supports, corrections, finalization, and downstream work byte-exact, and
returns failure. No worker may claim program or downstream work through that
barrier.

The F10 diagnostic envelope is exactly:

```text
6|M17_INPUT_FINALIZED|ERROR|m17.reference/m17_reference.item_source.occurred_at|55000|timed input changed finalized window [7,1]|Restore the authoritative input to the finalized aggregate, then reconcile the program.|{"complete_watermark":"1970-01-01T03:15:00.000000Z","event_time":"1970-01-01T01:45:00.000000Z","lateness_boundary":"1970-01-01T02:15:00.000000Z","lower_frontier":10,"window_key":[7,1]}
```

The operator deletes item 8 and calls `reconcile_program('m17.reference')`.
Reconciliation recomputes every protected finalized summary. Exact equality
with the retained F9 state advances the complete lower frontier to F11, clears
the barrier, records one `LATE_INPUT_REPAIRED` audit, and creates no correction
or lifecycle event. A mismatch retains the barrier. Missing correction or
finalization identity is not invented: it returns
`M17_HISTORY_UNRECOVERABLE` and requires physical restore.

Other frozen diagnostics are:

| Condition | SQLSTATE | Code | Mutation |
|---|---|---|---|
| backward watermark | `22023` | `M17_WATERMARK_BACKWARD` | none |
| null event time | `22004` | `M17_EVENT_TIME_NULL` | none |
| infinite event time | `22008` | `M17_EVENT_TIME_INFINITE` | none |
| invalid duration/lateness | `22023` | `M17_WINDOW_INTERVAL_INVALID` | none |
| earliest boundary exceeds batch bound | `54000` | `M17_WATERMARK_BATCH_LIMIT` | none |
| injected advancement failure | original SQLSTATE | `M17_WATERMARK_BATCH_FAILED` | retain last complete batch |

All use the inherited versioned envelope order shown by the F10 row. Drift,
unauthorized access, overflow, unsupported types, multiple windows, recursion,
and same-stratum input retain their inherited exact diagnostic classifications
and add no temporal state.

## Evidence, retention, limits, and recovery

Current evidence has one row for every materialized window-rule state, including
false and null truth. In canonical order it exposes program/rule identity,
public key, relation, function/expression/types, event-time column,
`duration_us`, UTC epoch alignment, start/end, requested/complete watermark,
lateness boundary, final flag, exact aggregate value, comparison/threshold,
last correction identity/frontier, current program lower frontier, truth, and
support generation. It never enumerates input rows.

For a true fact, unified explanation is exactly the corresponding current
evidence row prefixed by `target|key|support`; false/null facts return SQL null.
At the final F11 checkpoint, requested and complete are both `03:15Z`, program
lower frontier is F11, and the ten true explanations use these last corrections:

```text
m17_reference.count_all_alert|[7,1]|G1|m17.reference@1/m17.count_all@1/[7,1]/F7
m17_reference.count_all_alert|[7,2]|G1|m17.reference@1/m17.count_all@1/[7,2]/F9
m17_reference.count_amount_alert|[7,1]|G1|m17.reference@1/m17.count_amount@1/[7,1]/F7
m17_reference.max_amount_alert|[7,0]|G2|m17.reference@1/m17.max_amount@1/[7,0]/F6
m17_reference.max_amount_alert|[7,1]|G1|m17.reference@1/m17.max_amount@1/[7,1]/F7
m17_reference.max_amount_alert|[7,2]|G1|m17.reference@1/m17.max_amount@1/[7,2]/F9
m17_reference.min_amount_alert|[7,1]|G1|m17.reference@1/m17.min_amount@1/[7,1]/F7
m17_reference.sum_amount_alert|[7,0]|G2|m17.reference@1/m17.sum_amount@1/[7,0]/F6
m17_reference.sum_amount_alert|[7,1]|G1|m17.reference@1/m17.sum_amount@1/[7,1]/F7
m17_reference.sum_amount_alert|[7,2]|G1|m17.reference@1/m17.sum_amount@1/[7,2]/F9
```

M17 performs no automatic temporal pruning. An operator supplies a monotone
event-time cutoff; that committed cutoff is the published recovery horizon.
Only superseded corrections for windows whose lateness boundary is strictly
before the cutoff may be removed. Current window summaries, latest correction
identity, finalization identity, watermark, lifecycle/idempotency identity,
active or rollback-eligible versions, and anything referenced by pending work,
reconciliation, replay, or recovery are never removed. Every attempt is one
audited transaction. At cutoff `01:15Z`, the reference deletes exactly the five
F1 corrections for `[7,-1]`, retains its five F3 corrections and finalization,
sets `history_floor = 01:15Z`, and reports
`windows=1|corrections=5|blocked=0`; repeating it reports all zeroes.

For windowed programs, inherited `max_facts` also bounds all materialized
window-rule states, including false/null states; one committed lower delta can
write at most that many corrections. `max_iterations`, `batch_size`,
`max_pending_jobs`, and PostgreSQL expression/statement limits remain in force.
Public correction/explanation history requires an explicit limit in `1..1000`
and stable codec-v2 cursor; there is no unbounded enumeration. Any limit,
catalog, expression, overflow, drift, or injected failure commits no partial
lower frontier or watermark batch.

Program replacement locks after timed input, carries the logical input's
watermarks, and seeds the new immutable version from one clean recomputation at
the current complete watermark; old history remains through the recovery
horizon. Identical `m17.reference@2` therefore has the exact F11 current state
(whose values equal F9), no lifecycle event, and exactly 20 version-2 seed
corrections at F11 in codec/rule order. Removal blocks new work and retains the
same recovery evidence until an audited prune is legal.

Crash/restart, managed-worker restart, and physical restore reproduce the last
complete lower frontier and watermark batch, then resume idempotently. Logical
dump/restore rebuilds physical OIDs but preserves logical declarations,
codec-v2 keys, correction/finalization identities, watermarks, current state,
and ordered history byte-for-byte. A populated direct `0.13.0 -> 0.14.0`
upgrade preserves every M16 object and row; existing unwindowed programs gain
no window state and no watermark. Rollback remains restore of the verified
pre-upgrade physical backup; SQL downgrade is unsupported.

## Entry decision

The immutable predecessor and behavioral oracle are frozen. No M17 schema,
migration, API implementation, worker change, or version bump is authorized by
this record. Product implementation remains blocked until the M17 contract and
executable fixture reproduce these normalized outputs exactly.
