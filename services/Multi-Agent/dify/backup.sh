# backup.sh (services/Multi-Agent/dify) — DB-aware backup/restore hooks.
# Sourced on demand by services.sh's Backup/Restore menu options — never
# exec'd directly, so this file is function definitions only, no top-level
# code. See services/_template/backup.sh.template for the shared reasoning.
#
# ── WHAT IS AND IS NOT COVERED ──────────────────────────────────────────
# Dify keeps EVERYTHING under the install directory as bind mounts, not named
# volumes: ./volumes/db/data (Postgres), ./volumes/redis, ./volumes/app/storage
# (uploaded files and knowledge-base documents), ./volumes/weaviate (the
# vector index), ./volumes/plugin_daemon. So the generic install-tree copy
# already captures the lot — this file only adds a consistent database dump
# on top, because a raw file copy of a RUNNING Postgres is a coin toss.
#
# The credentials are read from Dify's own .env, which deploy.sh generated —
# never from upstream's .env.example, whose DB_PASSWORD is the published
# `difyai123456`.
#
# Note the container name comes from DockHub's docker-compose.override.yml
# (`dify-db`). Upstream sets no container_name on its database, so without
# that override there is no stable target for docker exec.

backup_dify() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local _derr; _derr="$(mktemp)"

    local pg_user pg_db
    pg_user="$(read_env_value DB_USERNAME "$install_dir/.env")"
    pg_db="$(read_env_value DB_DATABASE "$install_dir/.env")"
    # Upstream's own defaults, applied only if the keys are absent — they are
    # commented out in some .env.example revisions rather than set.
    pg_user="${pg_user:-postgres}"
    pg_db="${pg_db:-dify}"

    if docker exec dify-db pg_dump -U "$pg_user" "$pg_db" > "$dump_file" 2>"$_derr"; then
        print_info "Database dumped to $dump_file"
    else
        print_warn "pg_dump failed — the archive will hold only a raw (less safe) copy of ./volumes/db."
        [[ -s "$_derr" ]] && sed 's/^/    /' "$_derr" >&2
        rm -f "$dump_file"
    fi
    rm -f "$_derr"

    backup_service_generic "dify" "$instance" "$install_dir"
}

restore_dify() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "dify" "$instance" "$install_dir" "$archive"

    # -s, not -f: an EMPTY dump would make the code below drop the database
    # and then load nothing into it.
    [[ -s "$install_dir/db.sql" ]] || {
        [[ -f "$install_dir/db.sql" ]] && {
            print_warn "db.sql is empty — the file restore stands, nothing was replayed."
            rm -f "$install_dir/db.sql"
        }
        return 0
    }

    local pg_user pg_db
    pg_user="$(read_env_value DB_USERNAME "$install_dir/.env")"
    pg_db="$(read_env_value DB_DATABASE "$install_dir/.env")"
    pg_user="${pg_user:-postgres}"
    pg_db="${pg_db:-dify}"

    # Only the database. Starting the rest would let Dify's api and worker run
    # migrations against the schema we are about to replace.
    (cd "$install_dir" && $(compose_cmd) up -d db_postgres) || true

    local _i _ready=0
    for (( _i = 1; _i <= 30; _i++ )); do
        if docker exec dify-db pg_isready -h localhost -U "$pg_user" -d "$pg_db" >/dev/null 2>&1; then
            _ready=1; break
        fi
        sleep 2
    done
    if (( ! _ready )); then
        print_warn "dify-db did not become ready in 60s. The file restore stands; the dump was NOT replayed."
        return 0
    fi

    # restore_service_generic already put ./volumes/db/data back, so the
    # database is a complete copy of itself — replaying into it fails on every
    # statement while psql exits 0 regardless. Drop, recreate, replay.
    local _e
    _e="$(docker exec dify-db dropdb --force --if-exists -U "$pg_user" "$pg_db" 2>&1)" \
      && _e="$(docker exec dify-db createdb -U "$pg_user" -O "$pg_user" "$pg_db" 2>&1)" \
      || {
        print_warn "Could not recreate database '$pg_db': ${_e:-unknown error}"
        print_warn "SKIPPING the replay — the restored files are left intact and usable."
        rm -f "$install_dir/db.sql"
        return 0
      }

    if docker exec -i dify-db \
         psql -v ON_ERROR_STOP=1 --single-transaction -q \
              -U "$pg_user" -d "$pg_db" < "$install_dir/db.sql"; then
        print_info "Database restored from db.sql (dropped, recreated, replayed in one transaction)."
    else
        print_warn "db.sql failed to replay and was rolled back — '$pg_db' is now EMPTY."
        print_warn "Restore an older archive, or reload the dump by hand from the extracted tree."
    fi
    rm -f "$install_dir/db.sql"

    print_warn "Check SECRET_KEY in .env matches the backup you just restored — Dify encrypts"
    print_warn "stored model-provider API keys with it, and a mismatch leaves them unreadable."
}
