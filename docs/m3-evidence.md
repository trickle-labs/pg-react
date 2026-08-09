# M3 evidence

| M3 requirement | Evidence |
| --- | --- |
| Supported platform, maintenance, isolation, RLS, and worker protocol matrix | [`m3-compatibility.md`](m3-compatibility.md), `pgreact.worker_protocol_compatible()` |
| Roles, private catalogs, exact dispatch, recovery, failover, and rolling-upgrade procedures | [`m3-operations.md`](m3-operations.md), `tests/m3.sql` |
| Extension migration and OID rebuild, retention audit, health, metrics, fair claims, group budgets, and backpressure | `tests/m3-upgrade.sh`, `tests/m3.sql` |
| RC performance thresholds | [`m3-performance.md`](m3-performance.md), `tests/m3.sh` |
| Controlled internal pilot under load and recovery | [`m3-pilot.md`](m3-pilot.md), `tests/m3.sql` |

Run the full release-candidate evidence from a clean Compose database:

```sh
bash tests/m0.sh && bash tests/m1.sh && bash tests/m1-scale.sh && bash tests/m2.sh && bash tests/m3.sh && bash tests/m3-upgrade.sh
cargo test --no-default-features
```
