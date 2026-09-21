FROM ghcr.io/trickle-labs/pg-trickle/builder@sha256:8d0446c21ab3273b55c045a39c49120e9d7cde8e970954c3f81e7bee194fad95 AS builder

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --locked --release --jobs 1 --no-default-features --features pg18 && \
    cp target/release/libpg_react.so /build/libpg_react.so

# Published pg_trickle 0.108.0 image, pinned to the PostgreSQL 18.3 artifact.
FROM ghcr.io/trickle-labs/pg_trickle@sha256:4856c3e9bc4de8a839daf7309326da49921db28b1bfe2bc48567205b78ff65c7

ENV PG_REACT_INIT_VERSION=0.46.0

COPY pg_react.control /usr/share/postgresql/18/extension/pg_react.control
COPY sql/ /usr/share/postgresql/18/extension/
COPY --from=builder /build/libpg_react.so /usr/lib/postgresql/18/lib/pg_react.so
COPY docker/00-pg-trickle.sql /docker-entrypoint-initdb.d/10-pg-react.sql
COPY --chmod=755 bin/pg-reactd /usr/local/bin/pg-reactd
