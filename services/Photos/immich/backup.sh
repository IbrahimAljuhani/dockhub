# backup.sh (services/Photos/immich)
# DB-aware backup/restore override — see services/_template/backup.sh.template
# for why this exists. Adapted (not copied verbatim) because Immich's own
# .env uses DB_USERNAME/DB_DATABASE_NAME (not this repo's usual
# POSTGRES_USER/POSTGRES_DB names) and its db compose service key is
# 'database', not 'db'.
#
# This file must contain ONLY function definitions — services.sh sources it
# on demand, it is never exec'd as its own process.

backup_immich() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local _derr; _derr="$(mktemp)"

    local pg_user pg_db
    pg_user="$(read_env_value DB_USERNAME "$install_dir/.env")"
    pg_db="$(read_env_value DB_DATABASE_NAME "$install_dir/.env")"

    if docker exec immich-db pg_dump -U "$pg_user" "$pg_db" > "$dump_file" 2>"$_derr"; then
        print_info "Database dumped to $dump_file"
    else
        print_warn "pg_dump failed — falling back to a raw (less safe) volume copy for the db."
        [[ -s "$_derr" ]] && sed "s/^/    /" "$_derr" >&2
        rm -f "$dump_file"
    fi

    # Still capture compose files/.env, the photo library, and the
    # machine-learning model cache the normal way — this only replaces how
    # the db data itself gets backed up.
    rm -f "$_derr"
    backup_service_generic "immich" "$instance" "$install_dir"
}

restore_immich() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "immich" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        local pg_user pg_db
        pg_user="$(read_env_value DB_USERNAME "$install_dir/.env")"
        pg_db="$(read_env_value DB_DATABASE_NAME "$install_dir/.env")"
        # db container needs to be up (but the app itself doesn't) for this —
        # services.sh's restore_menu already ran `compose down` before
        # calling this, so bring just the database service back up first.
        (cd "$install_dir" && $(compose_cmd) up -d database) || true

        # Readiness, not a fixed sleep — a sleep is a bet that the restoring
        # machine is no slower than the one the sleep was written on.
        local _r _i _e
        _r=0; for _i in $(seq 1 30); do
            docker exec "immich-db" pg_isready -h localhost -U "$pg_user" -d "$pg_db" >/dev/null 2>&1 && { _r=1; break; }
            sleep 2
        done
        if (( ! _r )); then
            print_warn "immich-db not ready in 60s. Volume restore stands; dump NOT replayed."
            rm -f "$install_dir/db.sql"; return 0
        fi

        # restore_service_generic ALREADY replaced the db volume, so the
        # database is a full copy of itself. Replaying into it errors on
        # every statement — and psql exits 0 anyway. Drop, recreate, replay.
        _e="$(docker exec "immich-db" dropdb --force --if-exists -U "$pg_user" "$pg_db" 2>&1)" \
          && _e="$(docker exec "immich-db" createdb -U "$pg_user" -O "$pg_user" "$pg_db" 2>&1)" \
          || { print_warn "Could not recreate $pg_db: ${_e:-unknown}"
               print_warn "SKIPPING the replay — the restored volume is intact and usable."
               rm -f "$install_dir/db.sql"; return 0; }
        if docker exec -i "immich-db" psql -v ON_ERROR_STOP=1 --single-transaction -q \
               -U "$pg_user" -d "$pg_db" < "$install_dir/db.sql"; then
            print_info "Database restored from db.sql (dropped, recreated, replayed in one transaction)."
        else
            print_warn "db.sql failed to replay and was rolled back — $pg_db is now EMPTY."
        fi
        rm -f "$install_dir/db.sql"
    fi
}
