# Published pg_trickle v0.81.0 / PostgreSQL 18.3 image, pinned by manifest digest.
FROM ghcr.io/trickle-labs/pg_trickle@sha256:998ab948555e990dcffc9464f316b3abe6b05f9ebc8bd50f16d3bc5bf88ca65d

COPY pg_react.control /usr/share/postgresql/18/extension/pg_react.control
COPY sql/ /usr/share/postgresql/18/extension/
COPY docker/00-pg-trickle.sql /docker-entrypoint-initdb.d/10-pg-react.sql
