#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose)
resource_prefix="${COMPOSE_PROJECT_NAME}-m6-physical"
restore_container="${resource_prefix}-postgres"
restore_helper="${resource_prefix}-restore"
restore_volume="${resource_prefix}-data"
backup_dir="/tmp/${resource_prefix}"
backup_archive="/tmp/${resource_prefix}.tar.gz"
backup_checksum="${backup_archive}.sha256"

case "$COMPOSE_PROJECT_NAME" in
  ''|*[!a-z0-9_-]*) echo "unsafe COMPOSE_PROJECT_NAME: $COMPOSE_PROJECT_NAME" >&2; exit 1 ;;
esac
restore_data=$("${compose[@]}" exec -T postgres psql -X -U postgres -d postgres -Atc 'SHOW data_directory')
case "$restore_data" in
  /var/lib/postgresql/*) ;;
  *) echo "unexpected image data directory: $restore_data" >&2; exit 1 ;;
esac

cleanup_physical() {
  docker rm -f "$restore_container" "$restore_helper" >/dev/null 2>&1 || true
  docker volume rm "$restore_volume" >/dev/null 2>&1 || true
  "${compose[@]}" exec -T postgres rm -rf -- \
    "$backup_dir" "$backup_archive" "$backup_checksum" >/dev/null 2>&1 || true
  rm -f "$backup_archive" "$backup_checksum"
}
trap cleanup_physical EXIT

"${compose[@]}" exec -T postgres createdb -U postgres m6_recovery
for fixture in m6-recovery-setup m6-restart m6-recovery-restore; do
  "${compose[@]}" cp "tests/$fixture.sql" "postgres:/tmp/$fixture.sql" >/dev/null
done
"${compose[@]}" exec -T postgres psql -X -U postgres -d m6_recovery \
  -v ON_ERROR_STOP=1 -f /tmp/m6-recovery-setup.sql

"${compose[@]}" kill -s SIGKILL postgres >/dev/null
"${compose[@]}" up -d --no-build postgres >/dev/null
ready=false
for _ in {1..120}; do
  if "${compose[@]}" exec -T postgres pg_isready -U postgres -d m6_recovery >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true
"${compose[@]}" exec -T postgres psql -X -U postgres -d m6_recovery \
  -v ON_ERROR_STOP=1 -f /tmp/m6-restart.sql

"${compose[@]}" exec -T postgres pg_basebackup -U postgres -D "$backup_dir" -Fp -Xs --checkpoint=fast
"${compose[@]}" exec -T postgres pg_verifybackup "$backup_dir"
"${compose[@]}" exec -T postgres tar -C "$backup_dir" -czf "$backup_archive" .
"${compose[@]}" exec -T postgres sh -c 'sha256sum "$1" > "$2"' sh "$backup_archive" "$backup_checksum"
"${compose[@]}" exec -T postgres sha256sum -c "$backup_checksum"

primary_container=$("${compose[@]}" ps -q postgres)
docker cp "$primary_container:$backup_archive" "$backup_archive" >/dev/null
docker cp "$primary_container:$backup_checksum" "$backup_checksum" >/dev/null
docker run --rm --name "$restore_helper" --platform "$PG_REACT_PLATFORM" \
  -v "$backup_archive:$backup_archive:ro" -v "$backup_checksum:$backup_checksum:ro" \
  --entrypoint sha256sum "$PG_REACT_IMAGE" -c "$backup_checksum"

docker volume create "$restore_volume" >/dev/null
docker run --rm --name "$restore_helper" --platform "$PG_REACT_PLATFORM" \
  -v "$restore_volume:/var/lib/postgresql" -v "$backup_archive:$backup_archive:ro" \
  --entrypoint sh "$PG_REACT_IMAGE" -c 'mkdir -p "$1" && tar -xzf "$2" -C "$1"' \
  sh "$restore_data" "$backup_archive"
docker run -d --name "$restore_container" --platform "$PG_REACT_PLATFORM" \
  -e POSTGRES_PASSWORD=pgreact -v "$restore_volume:/var/lib/postgresql" \
  "$PG_REACT_IMAGE" postgres \
  -c shared_preload_libraries=pg_trickle \
  -c pg_trickle.user_triggers=auto \
  -c pg_trickle.enabled=off \
  -c pg_trickle.differential_max_change_ratio=1.0 \
  -c 'default_transaction_isolation=read committed' >/dev/null

ready=false
for _ in {1..120}; do
  if docker exec "$restore_container" pg_isready -U postgres -d m6_recovery >/dev/null 2>&1; then
    ready=true
    break
  fi
  if test "$(docker inspect "$restore_container" --format '{{.State.Running}}')" != true; then
    docker logs "$restore_container"
    break
  fi
  sleep 1
done
test "$ready" = true
test "$(docker inspect "$restore_container" --format '{{.Image}}')" = \
  "$(docker image inspect "$PG_REACT_IMAGE" --format '{{.Id}}')"
docker cp tests/m6-recovery-restore.sql "$restore_container:/tmp/m6-recovery-restore.sql" >/dev/null
docker exec "$restore_container" psql -X -U postgres -d m6_recovery -v ON_ERROR_STOP=1 \
  -f /tmp/m6-recovery-restore.sql

echo "M6 crash restart and physical recovery passed"
