# backup.sh (services/ERP/dolibarr)
# DB-aware backup/restore override — see services/_template/backup.sh.template
# for why this exists. The generic volume copy handles the documents and
# custom-module volumes correctly, but would raw-copy live MariaDB data
# files, which can produce a subtly corrupt, unrestorable dump.
#
# Unlike this repo's ERPNext backup, a single named database is dumped rather
# than --all-databases: Dolibarr's database name and user are fixed values
# this deployment chose (dolidb / dolidbuser) and are recreated by the
# compose file's MARIADB_* variables on restore, so the mysql system tables
# don't need to travel with the data.
#
# MariaDB 11 renamed the client binaries (mysqldump -> mariadb-dump); the old
# names survive as deprecated symlinks, so each command tries the new one
# first.
#
# This file must contain ONLY function definitions — services.sh sources it
# on demand, it is never exec'd as its own process.

# Picks whichever client binary this MariaDB image actually ships.
# $1 = new-style name, $2 = legacy name.
_dolibarr_db_bin() {
    if docker exec dolibarr-db sh -c "command -v $1" >/dev/null 2>&1; then
        echo "$1"
    else
        echo "$2"
    fi
}

# ─────────────────────────────────────────────────────────────────────
# WHY THIS FILE HAS NO dropdb/createdb, UNLIKE THE POSTGRES ONES
#
# The Postgres services in this repo were fixed on 2026-08-19: their dump
# replayed onto a database restore_service_generic had ALREADY replaced,
# every statement failed with "already exists", and psql exited 0 anyway.
# The fix there is drop-recreate-replay.
#
# THAT FIX MUST NOT BE COPIED HERE, and the reason is a real difference:
# mysqldump enables --opt by default, and --opt includes --add-drop-table.
# So the dump already begins each table with DROP TABLE IF EXISTS, and
# replaying it onto a populated database is correct. Confirm on any real
# dump with:  head -40 db.sql | grep -i "drop table"
#
# Two further reasons not to reach for DROP DATABASE here:
#   · mysql stops at the first error and returns non-zero by DEFAULT, so
#     unlike psql its exit status is already trustworthy. No ON_ERROR_STOP
#     equivalent is needed because the behaviour is the default.
#   · wordpress has no root credentials at all — its compose sets
#     MYSQL_RANDOM_ROOT_PASSWORD, so the password is generated and never
#     stored. Dropping the database with the app user and then failing to
#     recreate it would destroy the data with no way back.
#
# The one thing this does NOT give you: a table that exists now but was not
# in the dump survives the restore, because mysqldump only drops what it
# recreates. Accepted deliberately — it is a far smaller risk than the one
# above.
# ─────────────────────────────────────────────────────────────────────
backup_dolibarr() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local _derr; _derr="$(mktemp)"

    local db_name db_password dump_bin
    db_name=$(read_env_value "DOLI_DB_NAME" "$install_dir/.env")
    db_password=$(read_env_value "DOLI_DB_ROOT_PASSWORD" "$install_dir/.env")
    dump_bin=$(_dolibarr_db_bin mariadb-dump mysqldump)

    # --single-transaction snapshots consistently without locking the server,
    # which matters because Dolibarr's cron jobs keep writing during a
    # backup. --routines/--events are included because Dolibarr installs both.
    if docker exec -e MYSQL_PWD="$db_password" dolibarr-db "$dump_bin" -uroot \
        --single-transaction --routines --events "$db_name" > "$dump_file" 2>"$_derr"; then
        print_info "Database '$db_name' dumped to $dump_file"
    else
        print_warn "$dump_bin failed — falling back to a raw (less safe) volume copy for the db."
        [[ -s "$_derr" ]] && sed "s/^/    /" "$_derr" >&2
        rm -f "$dump_file"
    fi

    # Still capture the compose files, .env (which holds the encryption salt)
    # and the documents/custom volumes the normal way.
    rm -f "$_derr"
    backup_service_generic "dolibarr" "$instance" "$install_dir"
}

restore_dolibarr() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "dolibarr" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        local db_name db_password client_bin
        db_name=$(read_env_value "DOLI_DB_NAME" "$install_dir/.env")
        db_password=$(read_env_value "DOLI_DB_ROOT_PASSWORD" "$install_dir/.env")
        # The db container needs to be up (the app doesn't) — services.sh's
        # restore_menu ran `compose down` first, so bring just the db back
        # and wait for it to accept connections.
        (cd "$install_dir" && $(compose_cmd) up -d dolibarr-db) || true
        client_bin=$(_dolibarr_db_bin mariadb mysql)
        local waited=0
        while (( waited < 60 )); do
            docker exec -e MYSQL_PWD="$db_password" dolibarr-db "$client_bin" -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
            sleep 3
            waited=$(( waited + 3 ))
        done

        if docker exec -i -e MYSQL_PWD="$db_password" dolibarr-db "$client_bin" -uroot "$db_name" < "$install_dir/db.sql"; then
            print_info "Database restored from db.sql"
            rm -f "$install_dir/db.sql"
        else
            print_warn "Failed to restore db.sql — the file has been left at $install_dir/db.sql so you can retry by hand."
        fi
    fi

    print_warn "Check that DOLI_INSTANCE_UNIQUE_ID in .env matches the backup you just restored — stored passwords and API keys are encrypted with it and are unreadable without the original value."
}
