# backup.sh (services/Photos/photoprism)
# DB-aware backup/restore override — see services/_template/backup.sh.template
# for why this exists. Adapted (not copied verbatim) because PhotoPrism uses
# MariaDB (mariadb-dump/mariadb clients) with its own PHOTOPRISM_DATABASE_*
# variable names, and its db compose service key is 'mariadb', not 'db'.
#
# Note this backs up the DATABASE (the index: albums, faces, labels, ratings,
# metadata). Your actual photo files live in the ORIGINALS_PATH folder you
# chose at deploy time, which is outside ~/docker/photoprism/ and therefore
# outside this backup — back that folder up separately, it's the
# irreplaceable half. See README.md.
#
# This file must contain ONLY function definitions — services.sh sources it
# on demand, it is never exec'd as its own process.

# ─────────────────────────────────────────────────────────────────────
# WHY THIS FILE HAS NO dropdb/createdb, UNLIKE THE POSTGRES ONES
#
# The Postgres services here were fixed on 2026-08-19: their dump replayed
# onto a database restore_service_generic had ALREADY replaced, every
# statement failed with "already exists", and psql exited 0 regardless.
#
# THAT FIX MUST NOT BE COPIED HERE. mariadb-dump is a mysqldump fork and
# shares its --opt default, which includes --add-drop-table — so the dump
# already begins each table with DROP TABLE IF EXISTS and replaying onto a
# populated database is correct. Confirm on a real dump with:
#     head -40 db.sql | grep -i "drop table"
# The mariadb client also stops at the first error and returns non-zero by
# default, so its exit status is trustworthy as written.
#
# This file was MISSED in the first sweep of that audit, because the sweep
# grepped for "mysql " and photoprism uses the "mariadb" client binaries.
# If you are auditing db hooks, match on mariadb-* too.
# ─────────────────────────────────────────────────────────────────────
backup_photoprism() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local _derr; _derr="$(mktemp)"

    local db_password
    db_password="$(read_env_value PHOTOPRISM_DATABASE_PASSWORD "$install_dir/.env")"

    # User/database names are fixed in docker-compose.yml (both "photoprism")
    # rather than being configurable, so they're not read from .env here.
    if docker exec photoprism-db mariadb-dump -uphotoprism -p"$db_password" photoprism > "$dump_file" 2>"$_derr"; then
        print_info "Database dumped to $dump_file"
    else
        print_warn "mariadb-dump failed — falling back to a raw (less safe) volume copy for the db."
        [[ -s "$_derr" ]] && sed "s/^/    /" "$_derr" >&2
        rm -f "$dump_file"
    fi

    # Still capture compose files/.env and the storage volume (cache,
    # thumbnails, sidecars) the normal way — this only replaces how the db
    # volume itself gets backed up.
    rm -f "$_derr"
    backup_service_generic "photoprism" "$instance" "$install_dir"
}

restore_photoprism() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "photoprism" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        local db_password
        db_password="$(read_env_value PHOTOPRISM_DATABASE_PASSWORD "$install_dir/.env")"
        # db container needs to be up (but the app itself doesn't) for this —
        # services.sh's restore_menu already ran `compose down` before
        # calling this, so bring just the mariadb service back up first.
        (cd "$install_dir" && $(compose_cmd) up -d mariadb) || true

        # Readiness, not `sleep 8`. A fixed sleep is a bet that the restoring
        # machine is no slower than the one the sleep was written on — and it
        # is lost silently, surfacing as a restore that "just failed".
        local _w=0
        while (( _w < 60 )); do
            docker exec photoprism-db mariadb -uphotoprism -p"$db_password" -e 'SELECT 1' >/dev/null 2>&1 && break
            sleep 3; _w=$(( _w + 3 ))
        done
        docker exec -i photoprism-db mariadb -uphotoprism -p"$db_password" photoprism < "$install_dir/db.sql" \
            && print_info "Database restored from db.sql" \
            || print_warn "Failed to restore db.sql — restore the volume backup manually if needed."
        rm -f "$install_dir/db.sql"
    fi
}
