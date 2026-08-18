# Historical M4 v1 GA evidence

> This record is immutable evidence for the old `0.1.1` release. Its “v1”
> wording predates the semantic-versioned `1.0.0` contract.

This record maps every Stage 4 requirement to executable or published
evidence for `pg-react:v0.1.1` on `linux/amd64`. The support boundary remains
the exact tuple frozen in the historical [M3 compatibility matrix](m3-compatibility.md).

| Requirement | Evidence |
| --- | --- |
| M3 entry gates on release bytes | `tests/m4.sh` builds the image once, verifies the running image ID, then runs `tests/m0.sh`, `m1.sh`, `m1-scale.sh`, `m2.sh`, and `m3.sh` against it. |
| Frozen public contract | The historical `docs/v1-release-notes.md` and `docs/m3-compatibility.md` describe the old composite type, views, overloads, protocol, migration window, and delivery semantics. `tests/m4-api.sql` detects API inventory drift. |
| Installation through troubleshooting guides | `docs/v1-installation.md`, `v1-authoring.md`, `m3-operations.md`, `v1-security.md`, `v1-backup-restore.md`, `v1-upgrades.md`, and `v1-troubleshooting.md`. |
| Reference example on every artifact | `tests/m4-reference.sql` copies the README's three-step rule; `tests/m4-reference.sh` runs it with `/usr/local/bin/pg-reactd` from the exact image and asserts the durable consequence. |
| No silent correctness blocker in scope | The inherited lifecycle, concurrency, dispatch, recovery, retention, scale, and upgrade suites run first. The M4 pilot additionally proves physical restore preserves identifiers and pending work and that a new post-restore `DIFFERENTIAL` refresh schedules and completes work. Logical live-rule restore is explicitly unsupported because the pinned dependency cannot rebuild its CDC metadata. |
| Release artifacts and disclosures together | `.github/workflows/release.yml` reruns Rust and image gates for exact tag `v0.1.1`, pushes the tested image, captures its digest, creates a checksummed OCI archive, and publishes it with `docs/v1-release-notes.md`. |
| Production exercise | `tests/m4-pilot.sh` and `tests/m4-pilot*.sql`; narrative record in `docs/m4-pilot.md`. |
| Small explicit support matrix | `docs/m3-compatibility.md`; no M4 compatibility widening. |

## Release gate

```sh
cargo fmt --check
cargo test --no-default-features
docker compose config --quiet
bash tests/m4.sh pg-react:v0.1.1
```

On 2026-08-09 the full image gate passed on the final physical-recovery design.
The restored clone completed its pre-backup pending episode, then pg_trickle
reported `DIFFERENTIAL: +1 -0` for a new fact and the resulting episode
completed. The API inventory, README workflow, M0–M3 suites, and direct upgrade
all passed in that same run. A focused API rerun also passed after adding the
parameter-name/default freeze.

The image gate includes installation, API freeze, exact README workflow,
normal and failing execution, physical `pg_basebackup` verification and
restore, recovery barriers, metadata rebuild, state-only reconciliation,
pending-work completion, a fresh differential transition after restore,
payload pruning, and the packaged `0.1.0 -> 0.1.1` upgrade.

The GitHub release job also runs the pinned PostgreSQL 18 pgrx builder check.
Publication is intentionally limited to the exact `v0.1.1` tag so unvalidated
branch images cannot become GA artifacts.
