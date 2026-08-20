# backup.sh (services/Web/wordpress)
# DB-aware backup/restore override — see services/_template/backup.sh.template
# for why this exists. Adapted (not copied verbatim) because WordPress uses
# MySQL (mysqldump/mysql), not Postgres (pg_dump/psql) like the template's
# default example.
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
backup_wordpress() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local _derr; _derr="$(mktemp)"

    local db_user db_password db_name
    db_user="$(read_env_value WORDPRESS_DB_USER "$install_dir/.env")"
    db_password="$(read_env_value WORDPRESS_DB_PASSWORD "$install_dir/.env")"
    db_name="$(read_env_value WORDPRESS_DB_NAME "$install_dir/.env")"

    if docker exec -e MYSQL_PWD="$db_password" wordpress-db mysqldump -u"$db_user" "$db_name" > "$dump_file" 2>"$_derr"; then
        print_info "Database dumped to $dump_file"
    else
        print_warn "mysqldump failed — falling back to a raw (less safe) volume copy for the db."
        [[ -s "$_derr" ]] && sed "s/^/    /" "$_derr" >&2
        rm -f "$dump_file"
    fi

    # Still capture compose files/.env and the wordpress-data volume (core
    # files, themes, plugins, uploads) the normal way — this only replaces
    # how the db volume itself gets backed up.
    rm -f "$_derr"
    backup_service_generic "wordpress" "$instance" "$install_dir"
}

restore_wordpress() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "wordpress" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        local db_user db_password db_name
        db_user="$(read_env_value WORDPRESS_DB_USER "$install_dir/.env")"
        db_password="$(read_env_value WORDPRESS_DB_PASSWORD "$install_dir/.env")"
        db_name="$(read_env_value WORDPRESS_DB_NAME "$install_dir/.env")"
        # db container needs to be up (but the app itself doesn't) for this —
        # services.sh's restore_menu already ran `compose down` before
        # calling this, so bring just the db service back up first.
        (cd "$install_dir" && $(compose_cmd) up -d db) || true

        # Readiness, not `sleep 5`. A fixed sleep is a bet that the restoring
        # machine is no slower than the one the sleep was written on, and it
        # is lost silently — as a restore that "just failed". dolibarr and
        # ghost already waited properly; this one did not.
        local _w=0
        while (( _w < 60 )); do
            docker exec -e MYSQL_PWD="$db_password" wordpress-db mysql -u"$db_user" -e 'SELECT 1' >/dev/null 2>&1 && break
            sleep 3; _w=$(( _w + 3 ))
        done

        # mysql stops at the first error and returns non-zero by default, so
        # unlike psql this exit status can be trusted as written.
        if docker exec -i -e MYSQL_PWD="$db_password" wordpress-db mysql -u"$db_user" "$db_name" < "$install_dir/db.sql"; then
            print_info "Database restored from db.sql"
            rm -f "$install_dir/db.sql"
        else
            print_warn "Failed to restore db.sql — the file has been left at $install_dir/db.sql so you can retry by hand."
        fi
    fi
}
