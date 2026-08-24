# M12 contract — database-time deadlines

M12 is extension and bundled-worker version `0.9.0`. It adds one deadline
declaration to the M11 PostgreSQL-first API without adding another rule or
timer language.

## Declaration and truth

`pgreact_api.validate_deadline_rule` and
`pgreact_api.author_deadline_rule` accept one ordinary condition view, one
non-null `bigint` semantic key, and one direct finite non-null `timestamptz`
deadline column. A candidate is due exactly when the committed durable clock
frontier is greater than or equal to its deadline. Equality is due.

Computed or volatile time expressions and recursive, negative, aggregate,
windowed, derived-program, recurring, RLS-protected, ambiguous, unauthorized,
null, infinite, or otherwise unsupported declarations fail with a version-2
diagnostic and no partial mutation.

## Clock and atomicity

The coordinator samples PostgreSQL once per pass and persists
`max(previous_frontier, sampled_time)`. Backward adjustment pauses temporal
progress; it never retracts a due match. A forward jump or coordinator outage
catches up every indexed candidate in `(previous_frontier, frontier]` once.

Every deadline candidate remains in the inherited explicit `DIFFERENTIAL`
stream, indexed by `(deadline, semantic_key)`. Source refreshes reconcile
changed keys. Clock passes inspect only crossing index entries. The coordinator
commits frontier, activation, lifecycle, agenda, and public clock evidence in
one `READ COMMITTED` transaction behind committed inherited claim barriers.
Any failure retains the previous complete frontier and exposes no partial work.

The default pass limit is 100,000 crossing keys and the default clock-lag
warning is one minute. A standby rejects advancement. Restart, physical
restore, and promotion retain the frontier and catch up on the first successful
primary pass.

## Lifecycle

- Insert or advance to an already-due deadline: activate on source refresh.
- Postpone an active deadline: deactivate; reaching it later creates the next
  generation.
- Delete: deactivate once.
- Pause: preserve current state and omit the rule from clock advancement.
- Resume: refresh and catch up once at the current frontier.
- Replace: deploy one new immutable deadline declaration under normal old-work
  policy.
- Remove: drop the maintained stream and deadline index; no active schedule
  remains.
- Reconcile: repair current due state without synthesizing events.

Equivalent supported source/clock orderings produce the same normalized state
and evidence at one frontier. Scheduler retries never duplicate a transition.
Consequences remain asynchronous and at-least-once; M12 promises neither exact
wall-clock latency nor source-transaction synchrony.

## Public inventory

M12 retains every M11 function and adds
`author_deadline_rule`, `validate_deadline_rule`, `deadline_history`,
`pause_rule`, `resume_rule`, `reconcile_rule`, `replace_deadline_rule`, and
`remove_rule`. `rule_status`, `explain_rule`, and `health` return contract
version 2 and include name-first deadline and clock evidence. There is no
public timer object or timer identifier.

The supported tuple is unchanged from M11: PostgreSQL 18.3, pg_trickle 0.81.0,
pgrx 0.18.0, Linux `amd64`, explicit `DIFFERENTIAL`, `READ COMMITTED`, bigint-v1
keys, no RLS source views, physical recovery, and worker protocols 1 and 2.
