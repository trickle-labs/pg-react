#!/bin/sh
set -eu

source_db=${1:-foundation}
restored_db=${2:-pgreact_m2_restore}
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mdm_helper_config=${MDM_HELPER_CONFIG:-"$test_dir/pg-mdm-configure-helper.sql"}
dump_file=$(mktemp "${TMPDIR:-/tmp}/pgreact-m2-restore.XXXXXX")
restored_created=0

cleanup() {
    if [ "$restored_created" -eq 1 ]; then
        dropdb --force "$restored_db" || true
    fi
    rm -f "$dump_file" || true
}
trap cleanup 0 HUP INT TERM

psql --set=ON_ERROR_STOP=1 --dbname="$source_db" \
    --file="$test_dir/v0.48-restore-prepare.sql"
# pg_trickle creates a fresh database-identity row when its extension is installed.
pg_dump --format=custom --exclude-table-data='pgtrickle.pgt_capture_instance' \
    --dbname="$source_db" --file="$dump_file"
createdb --template=template0 "$restored_db"
restored_created=1
pg_restore --exit-on-error --dbname="$restored_db" "$dump_file"

for database in $(psql --dbname=postgres --tuples-only --no-align \
        --command="SELECT datname FROM pg_catalog.pg_database WHERE datallowconn"); do
    psql --set=ON_ERROR_STOP=1 --dbname="$database" \
        --file="$test_dir/v0.48-worker-role-detach.sql"
done
psql --set=ON_ERROR_STOP=1 --dbname=postgres \
    --file="$test_dir/v0.48-worker-role-create.sql"
psql --set=ON_ERROR_STOP=1 --set=helper_owner=mdm_helper_owner \
    --dbname="$restored_db" --file="$mdm_helper_config"
psql --set=ON_ERROR_STOP=1 --dbname="$restored_db" \
    --file="$test_dir/v0.48-restore-regrant.sql"
psql --set=ON_ERROR_STOP=1 --dbname="$restored_db" \
    --file="$test_dir/v0.48-restore.sql"
