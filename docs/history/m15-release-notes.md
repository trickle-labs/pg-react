# pg-react 0.12.0 — runtime and usability completion

M15 adds PostgreSQL-managed coordination and execution, portable scalar and
mixed tuple semantic keys, final public status/doctor/explain integration, and a
clean task-first workflow. The bundled external worker remains only for the
documented drain-and-transition path.

Supported keys are `bigint`, `uuid`, and `text COLLATE "C"`, with one to four
ordered non-null components. Existing `0.11.0` durable state and pending work are
preserved by the direct upgrade.

The release publishes `pg-react-v0.12.0-linux-amd64.tar.gz`, its SHA-256
manifest, and the immutable `linux/amd64` OCI digest after `tests/m15.sh` passes.
