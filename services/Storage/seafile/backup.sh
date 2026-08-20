# backup.sh (services/Storage/seafile)
# DB-aware backup/restore override — see services/_template/backup.sh.template
# for why this exists. The generic volume copy handles Seafile's data volume
# correctly but would raw-copy live MariaDB files, which can produce a subtly
# corrupt, unrestorable dump.
#
# --all-databases rather than named ones, for two reasons specific to
# Seafile: it uses THREE databases (ccnet_db, seafile_db, seahub_db) that
# must be restored as a consistent set, and its dedicated `seafile` MySQL
# user is created during first-run init and lives in the `mysql` system
# database — dumping only the three would restore the data but not the
# account allowed to read it.
#
# MariaDB 11 renamed the client binaries (mysqldump -> mariadb-dump). Seafile
# pins 10.11, where the old names are still primary, but each command tries
# the new name first so this keeps working when upstream moves the pin.
#
# This file must contain ONLY function definitions — services.sh sources it
# on demand, it is never exec'd as its own process.

# Picks whichever client binary this MariaDB image actually ships.
# $1 = new-style name, $2 = legacy name.
_seafile_db_bin() {
    if docker exec seafile-db sh -c "command -v $1" >/dev/null 2>&1; then
        echo "$1"
    else
        echo "$2"
    fi
}

# ─────────────────────────────────────────────────────────────────────
# WHY THIS FILE HAS NO dropdb/createdb, UNLIKE THE POSTGRES ONES
#
# The Postgres services here were fixed on 2026-08-19: their dump replayed
# onto a database restore_service_generic had ALREADY replaced, every
# statement failed with "already exists", and psql exited 0 regardless.
#
# THAT FIX MUST NOT BE COPIED HERE. This service dumps ALL databases, and a
# mysqldump/mariadb-dump of that shape emits CREATE DATABASE IF NOT EXISTS
# plus, from the default --opt/--add-drop-table, a DROP TABLE IF EXISTS
# before every CREATE TABLE. Replaying onto a populated server is therefore
# already correct and idempotent. Confirm on a real dump with:
#     head -40 db.sql | grep -iE "drop table|create database"
#
# The client also stops at the first error and returns non-zero by DEFAULT,
# so unlike psql its exit status is trustworthy as written — which is why
# the restore below can rely on a plain if/else.
# ─────────────────────────────────────────────────────────────────────
backup_seafile() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local _derr; _derr="$(mktemp)"

    local db_password dump_bin
    db_password=$(read_env_value "INIT_SEAFILE_MYSQL_ROOT_PASSWORD" "$install_dir/.env")
    dump_bin=$(_seafile_db_bin mariadb-dump mysqldump)

    # --single-transaction snapshots consistently without locking the server;
    # Seafile's background jobs keep writing throughout a backup.
    if docker exec -e MYSQL_PWD="$db_password" seafile-db "$dump_bin" -uroot \
        --all-databases --single-transaction --routines --events > "$dump_file" 2>"$_derr"; then
        print_info "Databases dumped to $dump_file"
    else
        print_warn "$dump_bin failed — falling back to a raw (less safe) volume copy for the db."
        [[ -s "$_derr" ]] && sed "s/^/    /" "$_derr" >&2
        rm -f "$dump_file"
    fi

    # Still capture compose files, .env (which holds JWT_PRIVATE_KEY) and the
    # seafile-data volume — every uploaded file lives there.
    rm -f "$_derr"
    backup_service_generic "seafile" "$instance" "$install_dir"
}

restore_seafile() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "seafile" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        local db_password client_bin
        db_password=$(read_env_value "INIT_SEAFILE_MYSQL_ROOT_PASSWORD" "$install_dir/.env")
        # The db container needs to be up (the app doesn't) — services.sh's
        # restore_menu ran `compose down` first, so bring just the db back
        # and wait for it to accept connections.
        (cd "$install_dir" && $(compose_cmd) up -d seafile-db) || true
        client_bin=$(_seafile_db_bin mariadb mysql)
        local waited=0
        while (( waited < 90 )); do
            docker exec -e MYSQL_PWD="$db_password" seafile-db "$client_bin" -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
            sleep 3
            waited=$(( waited + 3 ))
        done

        if docker exec -i -e MYSQL_PWD="$db_password" seafile-db "$client_bin" -uroot < "$install_dir/db.sql"; then
            print_info "Databases restored from db.sql"
            rm -f "$install_dir/db.sql"
        else
            print_warn "Failed to restore db.sql — the file has been left at $install_dir/db.sql so you can retry by hand."
        fi

        # --all-databases overwrote the `mysql` system database wholesale, so
        # the server is still serving the pre-restore grant tables until it
        # is told otherwise. Without this the `seafile` user appears not to
        # exist and the app can't connect.
        docker exec -e MYSQL_PWD="$db_password" seafile-db "$client_bin" -uroot -e 'FLUSH PRIVILEGES' >/dev/null 2>&1 \
            || print_warn "Could not flush privileges — restart the seafile-db container before starting the app."
    fi

    print_warn "Check that JWT_PRIVATE_KEY in .env matches the backup you just restored — it signs Seafile's internal service tokens, and a mismatch breaks the file server while the web UI still loads."
}
