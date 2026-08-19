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

# ── TWO databases, not one ──────────────────────────────────────────────
# Dify runs a second Postgres database for its plugin daemon. Upstream's
# compose says so plainly:
#
#     plugin_daemon:
#       environment:
#         DB_DATABASE: ${DB_PLUGIN_DATABASE:-dify_plugin}
#
# The first version of this file dumped only DB_DATABASE (`dify`) and left
# `dify_plugin` untouched — so every installed plugin, its configuration and
# its stored credentials were absent from the dump, while the backup reported
# success. The raw volume copy is no defence: it is exactly the inconsistent
# mid-write snapshot the dump exists to replace.
_dify_dbs() {
    local install_dir="$1" main plug
    main="$(read_env_value DB_DATABASE        "$install_dir/.env")"
    plug="$(read_env_value DB_PLUGIN_DATABASE "$install_dir/.env")"
    # Upstream's own defaults, applied only when the key is absent — some
    # .env.example revisions ship them commented out rather than set.
    printf '%s %s\n' "${main:-dify}" "${plug:-dify_plugin}"
}

backup_dify() {
    local instance="$1" install_dir="$2"
    local _derr; _derr="$(mktemp)"

    local pg_user
    pg_user="$(read_env_value DB_USERNAME "$install_dir/.env")"
    pg_user="${pg_user:-postgres}"

    local db
    for db in $(_dify_dbs "$install_dir"); do
        local dump_file="$install_dir/db-${db}.sql"
        # A database that does not exist yet is not a failure: dify_plugin is
        # created on first plugin-daemon start, so a very fresh deployment can
        # legitimately be missing it.
        if ! docker exec dify-db psql -U "$pg_user" -d postgres -tAc \
               "SELECT 1 FROM pg_database WHERE datname = '$db'" 2>/dev/null | grep -q 1; then
            print_warn "Database '$db' does not exist yet — skipping its dump."
            rm -f "$dump_file"
            continue
        fi
        if docker exec dify-db pg_dump -U "$pg_user" "$db" > "$dump_file" 2>"$_derr"; then
            print_info "Database '$db' dumped to $(basename "$dump_file")"
        else
            print_warn "pg_dump of '$db' failed — the archive will hold only a raw copy of ./volumes/db."
            [[ -s "$_derr" ]] && sed 's/^/    /' "$_derr" >&2
            rm -f "$dump_file"
        fi
    done
    rm -f "$_derr"

    backup_service_generic "dify" "$instance" "$install_dir"
}

restore_dify() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "dify" "$instance" "$install_dir" "$archive"

    local pg_user
    pg_user="$(read_env_value DB_USERNAME "$install_dir/.env")"
    pg_user="${pg_user:-postgres}"

    # Anything to replay at all? Older archives, taken before this file dumped
    # two databases, carry a single `db.sql` — accepted and treated as the
    # main database, so a backup made yesterday still restores today.
    local db legacy=0
    [[ -s "$install_dir/db.sql" ]] && legacy=1
    if (( ! legacy )); then
        local any=0
        for db in $(_dify_dbs "$install_dir"); do
            [[ -s "$install_dir/db-${db}.sql" ]] && any=1
        done
        (( any )) || return 0
    fi

    # Only the database. Starting the rest would let Dify's api and worker run
    # migrations against the schema we are about to replace.
    (cd "$install_dir" && $(compose_cmd) up -d db_postgres) || true

    local _i _ready=0
    for (( _i = 1; _i <= 30; _i++ )); do
        if docker exec dify-db pg_isready -h localhost -U "$pg_user" >/dev/null 2>&1; then
            _ready=1; break
        fi
        sleep 2
    done
    if (( ! _ready )); then
        print_warn "dify-db did not become ready in 60s. The file restore stands; nothing was replayed."
        return 0
    fi

    # restore_service_generic already put ./volumes/db/data back, so each
    # database is a complete copy of itself — replaying into it fails on every
    # statement while psql exits 0 regardless. Drop, recreate, replay. Per
    # database, because these are two independent databases in one cluster
    # and a failure on one must not silently take the other with it.
    _dify_replay() {
        local db="$1" file="$2" _e
        [[ -s "$file" ]] || return 0
        _e="$(docker exec dify-db dropdb --force --if-exists -U "$pg_user" "$db" 2>&1)" \
          && _e="$(docker exec dify-db createdb -U "$pg_user" -O "$pg_user" "$db" 2>&1)" \
          || {
            print_warn "Could not recreate database '$db': ${_e:-unknown error}"
            print_warn "SKIPPING its replay — the restored files are left intact."
            rm -f "$file"; return 0
          }
        if docker exec -i dify-db \
             psql -v ON_ERROR_STOP=1 --single-transaction -q -o /dev/null -U "$pg_user" -d "$db" < "$file"; then
            print_info "Database '$db' restored (dropped, recreated, replayed in one transaction)."
        else
            print_warn "The dump for '$db' failed to replay and was rolled back — that database is now EMPTY."
            print_warn "Restore an older archive, or reload it by hand from the extracted tree."
        fi
        rm -f "$file"
    }

    if (( legacy )); then
        # Pre-2026-08-19 archive: one file, main database only. Say so, because
        # the plugin database will come back from the raw volume copy instead
        # and the user should know which half is which.
        print_warn "This archive predates plugin-database backups — only the main database has a dump."
        _dify_replay "$(_dify_dbs "$install_dir" | awk '{print $1}')" "$install_dir/db.sql"
    else
        for db in $(_dify_dbs "$install_dir"); do
            _dify_replay "$db" "$install_dir/db-${db}.sql"
        done
    fi
    unset -f _dify_replay

    print_warn "Check SECRET_KEY in .env matches the backup you just restored — Dify encrypts"
    print_warn "stored model-provider API keys with it, and a mismatch leaves them unreadable."
}
