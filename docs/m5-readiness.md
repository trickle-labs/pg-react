# M5 readiness

## Repository state

The `0.2.0` implementation, direct `0.1.1 -> 0.2.0` migration, public pack API, documentation, and complete Docker-backed M5 gate are implemented. The gate proves every M5 exit scenario on the existing supported `linux/amd64` PostgreSQL 18.3 / pg_trickle 0.81.0 boundary without widening RLS, key codec, recovery, platform, maintenance, or worker support.

## External entry gate — complete

On 2026-08-09, the public `v0.1.1` tag resolved to validated commit `31a2b4d85f6bb1cdd94a21337d94a98b40ee6b3d`. [Release run 31312006930](https://github.com/trickle-labs/pg-react/actions/runs/31312006930) completed successfully and published [release `v0.1.1`](https://github.com/trickle-labs/pg-react/releases/tag/v0.1.1) with its notes, limitations, archive, and checksum.

Independent verification matched:

- archive SHA-256: `81fcb7a839f5be91a9daf148fe649cfde9e8a8cb889a851b976e1d798d3979bc`
- OCI image: `ghcr.io/trickle-labs/pg-react:v0.1.1@sha256:9367198b3eec2832719f2fe15af6ad815ed1750d6a78c212cf9cf1063b2a2579`
- release notes: `linux/amd64`, physical recovery, RLS, dependency, and other supported-boundary disclosures are present

The complete `tests/m5.sh pg-react:m5-dev` gate was then rerun against implementation commit `0d6d37a749fe25ad0a44c860af548720f081f85e` and passed every compatibility, API, upgrade, rollback, concurrency, and promotion phase. Formatting, host tests, the pinned PostgreSQL 18 builder check, and Compose validation also pass. M5 is complete.

M6 is now defined in [`ROADMAP.md`](../ROADMAP.md) as execution maturity focused on audited batch execution. Planning and gate design may begin, but its product work remains behind the published `v0.2.0` release and measured-bottleneck entry gates.
