# M7 entry fixture

M7 product changes remain gated on publication and verification of the exact
`v0.3.0` release. This fixture freezes the semantic workload and normalized
public output without fixing SQL function signatures or changing the `0.3.0`
product.

## Reference model

The inherited support boundary is unchanged. Role `m7_owner` owns these
portable definitions:

| Object | Version | Row type or source binding | Semantic key |
| --- | ---: | --- | --- |
| `clinical.patient_fever` | 1 | `(patient_id bigint NOT NULL)` | `patient_id` |
| `clinical.fever_from_positive_test` | 1 | `(patient_id bigint, test_name text, positive boolean)` | `patient_id` |
| `clinical.fever_from_temperature` | 1 | `(patient_id bigint, temperature_c numeric(4,1))` | `patient_id` |
| `clinical.observe_patient_fever` | 1 | `(patient_id bigint)` | `patient_id` |

The first object is a derived relation. The next two are derivation rules that
each contribute one support for the same `patient_id = 42` fact. The last is a
downstream constraint rule that reads only the public derived relation. Neither
derivation rule reads derived state.

The source bindings are exactly:

```text
positive_test={"patient_id":42,"positive":true,"test_name":"influenza_a"}
temperature={"patient_id":42,"temperature_c":39.2}
```

## Ordered workload

| Frontier | Source change | Required result |
| --- | --- | --- |
| F0 | No source rows | No fact, support, or downstream activation |
| F1 | Add both source bindings | One fact, two supports, downstream `ACTIVATE` generation 1 |
| F2 | Remove `temperature` | The fact remains with the positive-test support; no downstream transition |
| F3 | Remove `positive_test` | The last support and fact retract; downstream `DEACTIVATE` generation 1 |
| F4 | Restore `temperature` | The fact returns with temperature activation generation 2; downstream `ACTIVATE` generation 2 |

F1 must produce the same normalized state when its two additions arrive in
either order. Repeating F2 and F3 in the opposite removal order must preserve
the fact after the first removal, retract it after the second, and produce the
same downstream history.

## Frozen normalized public output

Generated identifiers, timestamps, and physical names are normalized to the
portable identities below. Rows and JSON support arrays sort by portable rule
identity.

```text
frontier|patient_id|support_count
F1|42|2
F2|42|1
F4|42|1

frontier|rule|rule_version|activation_generation|patient_id|source_binding
F1|clinical.fever_from_positive_test|1|1|42|{"patient_id":42,"positive":true,"test_name":"influenza_a"}
F1|clinical.fever_from_temperature|1|1|42|{"patient_id":42,"temperature_c":39.2}
F2|clinical.fever_from_positive_test|1|1|42|{"patient_id":42,"positive":true,"test_name":"influenza_a"}
F4|clinical.fever_from_temperature|1|2|42|{"patient_id":42,"temperature_c":39.2}

frontier|event|generation|patient_id
F1|ACTIVATE|1|42
F3|DEACTIVATE|1|42
F4|ACTIVATE|2|42
```

The explanation result is one JSON value while the fact is current and SQL
`NULL` after F3. JSON object keys and support rows are normalized as shown.

```json
{"relation":"clinical.patient_fever@1","fact":{"patient_id":42},"active_supports":[{"rule":"clinical.fever_from_positive_test@1","activation_generation":1,"source_binding":{"patient_id":42,"positive":true,"test_name":"influenza_a"}},{"rule":"clinical.fever_from_temperature@1","activation_generation":1,"source_binding":{"patient_id":42,"temperature_c":39.2}}]}
{"relation":"clinical.patient_fever@1","fact":{"patient_id":42},"active_supports":[{"rule":"clinical.fever_from_positive_test@1","activation_generation":1,"source_binding":{"patient_id":42,"positive":true,"test_name":"influenza_a"}}]}
null
{"relation":"clinical.patient_fever@1","fact":{"patient_id":42},"active_supports":[{"rule":"clinical.fever_from_temperature@1","activation_generation":2,"source_binding":{"patient_id":42,"temperature_c":39.2}}]}
```

Support history after F4 is exact and survives retention for the duration of
the fixture:

```text
rule|rule_version|activation_generation|patient_id|active|first_frontier|last_frontier
clinical.fever_from_positive_test|1|1|42|false|F1|F3
clinical.fever_from_temperature|1|1|42|false|F1|F2
clinical.fever_from_temperature|1|2|42|true|F4|
```

## Reconciliation and recovery

At F4 the fault fixture deletes fact 42 and its generation-2 support, marks
both generation-1 supports active, and inserts unsupported fact 99.
Reconciliation must restore the exact F4 current fact, active support,
explanation, and downstream state above; remove fact 99; and expose one public
repair diagnostic for each missing, extra, or stale row. A second run is a
no-op with no repair diagnostics.

A physical backup taken after reconciliation is restored into a clean
supported cluster. The complete normalized current fact, support history,
explanation, downstream lifecycle history, dependencies, and frontier must be
byte-for-byte equal to the F4 output. Refreshing after restore is a no-op.

## Entry gate evidence

Verified on 2026-08-09: public tag `v0.3.0` and its release resolve to exact
commit `0d54b392292847eea1a07f91d721ff536b7eb8ad`. Release workflow run
`31322283638` passed the complete M6 gate, including the direct
`0.2.0 -> 0.3.0` upgrade, before publishing the disclosed archive and OCI
image. GitHub reports archive SHA-256
`6cc146276f26fae9a5178d06eac2d6103e811d516dcd7e999322e9ff5675a107`;
the attached checksum manifest agrees and records OCI digest
`sha256:620b7492c054e826fe8665239e2d833b4f90a10ed94425d7e26a1abccacda8a5`,
which the public `linux/amd64` tag resolves to. The release notes include the
upgrade procedure, support boundary, limitations, and artifact disclosures.
M7 product work may begin.
