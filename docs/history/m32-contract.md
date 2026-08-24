# M32 contract — PostgreSQL-native interface

M32 follows M31 / `0.28.0` and targets extension `0.29.0`. It changes the
ordinary interface and documentation, not the runtime meaning of existing
rules.

## One ordinary model

Ordinary users work with six ideas:

| Idea | Plain meaning |
| --- | --- |
| Condition | PostgreSQL data describing what is true |
| Rule | Connects a condition to lifecycle behavior |
| Action | A typed PostgreSQL function or registered delivery |
| Decision | Chooses a result from relational candidates |
| Policy set | Restricts an existing rule to eligible subjects |
| Work | Durable requested execution and its outcome |

## Canonical schema and verbs

New ordinary documentation uses the `pgreact` schema:

```sql
pgreact.rule
pgreact.validate
pgreact.preview
pgreact.deploy
pgreact.remove
pgreact.run
pgreact.status
pgreact.explain
pgreact.doctor
```

The ordinary inspection views are:

```text
pgreact.rules
pgreact.matches
pgreact.decisions
pgreact.policy_sets
pgreact.work
pgreact.attempts
pgreact.health
```

The released `pgreact_api` surface remains available as compatibility where
required. It is not the new-user path and must delegate to the authoritative
implementation rather than create a second behavior path.

## Safety rules

- Names are the routine target selector; internal UUIDs are advanced evidence.
- Conditions remain PostgreSQL relations or views.
- Common authoring does not require JSON.
- `pgreact.run()` is the only ordinary coordinator operation.
- Preview must identify create versus replacement and reject stale assumptions.
- Deployment must fail closed on invalid, inaccessible, ambiguous, or drifting
  PostgreSQL objects.
- Every finding has a stable code, severity, blocking flag, target, field,
  message, hint, and details.

## Scope

M32 freezes the ordinary interface and its documentation. It does not add a
new predicate language, a CI/CD promotion service, full hypothetical
deployment-impact simulation, or a promise that external usability evidence
already exists.
