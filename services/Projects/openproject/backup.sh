# backup.sh (services/Projects/openproject) — DB-aware backup/restore hooks.
# Sourced on demand by services.sh's Backup/Restore menu options — never
# exec'd directly, so this file is function definitions only, no top-level
# code. See services/_template/backup.sh.template for why this is separate
# from deploy.sh.

backup_openproject() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local _derr; _derr="$(mktemp)"

    # user/db are fixed in docker-compose.yml (postgres/openproject) — only
    # the password is templated via .env.
    if docker exec openproject-db pg_dump -U postgres openproject > "$dump_file" 2>"$_derr"; then
        print_info "Database dumped to $dump_file"
    else
        print_warn "pg_dump failed — falling back to a raw (less safe) volume copy for the db."
        [[ -s "$_derr" ]] && sed "s/^/    /" "$_derr" >&2
        rm -f "$dump_file"
    fi

    rm -f "$_derr"
    backup_service_generic "openproject" "$instance" "$install_dir"
}

restore_openproject() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "openproject" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        (cd "$install_dir" && $(compose_cmd) up -d db) || true

        # Readiness, not a fixed sleep — a sleep is a bet that the restoring
        # machine is no slower than the one the sleep was written on.
        local _r _i _e
        _r=0; for _i in $(seq 1 30); do
            docker exec "openproject-db" pg_isready -h localhost -U "postgres" -d "openproject" >/dev/null 2>&1 && { _r=1; break; }
            sleep 2
        done
        if (( ! _r )); then
            print_warn "openproject-db not ready in 60s. Volume restore stands; dump NOT replayed."
            rm -f "$install_dir/db.sql"; return 0
        fi

        # restore_service_generic ALREADY replaced the db volume, so the
        # database is a full copy of itself. Replaying into it errors on
        # every statement — and psql exits 0 anyway. Drop, recreate, replay.
        _e="$(docker exec "openproject-db" dropdb --force --if-exists -U "postgres" "openproject" 2>&1)" \
          && _e="$(docker exec "openproject-db" createdb -U "postgres" -O "postgres" "openproject" 2>&1)" \
          || { print_warn "Could not recreate openproject: ${_e:-unknown}"
               print_warn "SKIPPING the replay — the restored volume is intact and usable."
               rm -f "$install_dir/db.sql"; return 0; }
        if docker exec -i "openproject-db" psql -v ON_ERROR_STOP=1 --single-transaction -q \
               -U "postgres" -d "openproject" < "$install_dir/db.sql"; then
            print_info "Database restored from db.sql (dropped, recreated, replayed in one transaction)."
        else
            print_warn "db.sql failed to replay and was rolled back — openproject is now EMPTY."
        fi
        rm -f "$install_dir/db.sql"
    fi
}
