# M15 entry fixture

M15 starts from the immutable public `v0.11.0` release at commit `314caad`.

- Archive: `pg-react-v0.11.0-linux-amd64.tar.gz`
- Archive SHA-256: `94b66c9443bef7058d1c8c3e0a43217207cceb6d8f9edd1c78d1a8613ce94529`
- OCI image: `ghcr.io/trickle-labs/pg-react:v0.11.0@sha256:dea716a2119fcee68a19e0865fd50b67c9f1d2b50db5e111d3cc4204f30963a7`
- Successful release workflow: `31637994763`
- Populated direct-upgrade fixture: `tests/m14-upgrade.sql`

The frozen M15 task fixture is `tests/m15.sh`: clean and populated upgrades,
managed primary operation and restart, worker transition and backpressure,
all scalar codecs and ordered mixed tuples, rejection without partial mutation,
physical and logical restore, exact grants and inventory, and every documented
workflow. Rollback means stop managed workers and restore the pre-upgrade
physical backup; extension downgrade is unsupported.
