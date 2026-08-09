# M5 readiness

## Repository state

The `0.2.0` implementation, direct `0.1.1 -> 0.2.0` migration, public pack API, documentation, and complete Docker-backed M5 gate are implemented. The gate proves every M5 exit scenario on the existing supported `linux/amd64` PostgreSQL 18.3 / pg_trickle 0.81.0 boundary without widening RLS, key codec, recovery, platform, maintenance, or worker support.

## External entry-gate blocker

M5 is not complete for merge or release. On 2026-08-09, the GitHub tag lookup returned `404`, `gh release view v0.1.1 --repo trickle-labs/pg-react` returned `release not found`, and the release workflow had no runs. The local tag alone does not satisfy `ROADMAP.md` or `docs/m4-readiness.md`.

Before M5 can be declared complete:

1. Push the exact validated local `v0.1.1` tag to GitHub.
2. Let `.github/workflows/release.yml` rerun the frozen gates and publish the tested image.
3. Verify the GitHub release notes/limitations, OCI digest, archive, and attached SHA-256 checksum against the workflow outputs.
4. Rerun `bash tests/m5.sh pg-react:v0.2.0` on the commit intended to merge.

After those steps, update this record and the M5 completion record in `ROADMAP.md`. No M6 exists in the authoritative roadmap; do not begin an unnumbered post-GA direction until it is promoted with a demonstrated need, bounded prerequisites, non-goals, support matrix, and executable exit evidence.
