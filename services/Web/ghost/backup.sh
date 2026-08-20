# backup.sh (services/Web/ghost)
# DB-aware backup/restore override — see services/_template/backup.sh.template
# for why this exists. The generic volume copy handles Ghost's content volume
# (themes, images, uploaded media) correctly, but would raw-copy live MySQL
# data files, which can produce a subtly corrupt, unrestorable dump.
#
# Note this is MySQL, not MariaDB — Ghost supports MySQL 8 only, so the
# binaries here are mysqldump/mysql and there is no mariadb-* fallback to
# try (unlike this repo's Dolibarr and ERPNext backups).
#
# This file must contain ONLY function definitions — services.sh sources it
# on demand, it is never exec'd as its own process.

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
backup_ghost() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local _derr; _derr="$(mktemp)"

    local db_name db_password
    db_name=$(read_env_value "GHOST_DB_NAME" "$install_dir/.env")
    db_password=$(read_env_value "GHOST_DB_ROOT_PASSWORD" "$install_dir/.env")

    # --single-transaction snapshots consistently without locking the server.
    # Ghost keeps writing (scheduled posts, member events) during a backup.
    if docker exec -e MYSQL_PWD="$db_password" ghost-db mysqldump -uroot \
        --single-transaction --routines --events "$db_name" > "$dump_file" 2>"$_derr"; then
        print_info "Database '$db_name' dumped to $dump_file"
    else
        print_warn "mysqldump failed — falling back to a raw (less safe) volume copy for the db."
        [[ -s "$_derr" ]] && sed "s/^/    /" "$_derr" >&2
        rm -f "$dump_file"
    fi

    # Still capture compose files, .env and the ghost-content volume (themes,
    # images, media, routes.yaml) the normal way.
    rm -f "$_derr"
    backup_service_generic "ghost" "$instance" "$install_dir"
}

restore_ghost() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "ghost" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        local db_name db_password
        db_name=$(read_env_value "GHOST_DB_NAME" "$install_dir/.env")
        db_password=$(read_env_value "GHOST_DB_ROOT_PASSWORD" "$install_dir/.env")
        # The db container needs to be up (the app doesn't) — services.sh's
        # restore_menu ran `compose down` first, so bring just the db back
        # and wait for it to accept connections.
        (cd "$install_dir" && $(compose_cmd) up -d ghost-db) || true
        local waited=0
        while (( waited < 60 )); do
            docker exec -e MYSQL_PWD="$db_password" ghost-db mysql -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
            sleep 3
            waited=$(( waited + 3 ))
        done

        if docker exec -i -e MYSQL_PWD="$db_password" ghost-db mysql -uroot "$db_name" < "$install_dir/db.sql"; then
            print_info "Database restored from db.sql"
            rm -f "$install_dir/db.sql"
        else
            print_warn "Failed to restore db.sql — the file has been left at $install_dir/db.sql so you can retry by hand."
        fi
    fi

    print_warn "Check that GHOST_URL in .env matches the site you just restored — Ghost stores absolute URLs, and a mismatch shows up as broken links and an admin panel that redirects away."
}
