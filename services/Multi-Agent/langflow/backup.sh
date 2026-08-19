# backup.sh (services/Multi-Agent/langflow) — DB-aware backup/restore hooks.
# Sourced on demand by services.sh's Backup/Restore menu options (see
# load_service_backup_hooks() there) — never exec'd directly, so this file is
# function definitions only, no top-level code.
#
# Langflow's state is split across two places:
#   · Postgres        — flows, users, API keys, global variables (encrypted)
#   · ./data (bind)   — uploaded files, component cache, logs
# The generic backup captures the second and would take a raw, mid-write copy
# of the first. A pg_dump is a consistent snapshot; a file copy of a running
# database is a coin toss.
#
# ── The key is in .env here, not in the data directory ──────────────────
# Langflow encrypts stored credentials (global variables of type Secret —
# your model-provider API keys) with LANGFLOW_SECRET_KEY, and deploy.sh
# writes that into .env, which sits inside the install tree and therefore
# inside the archive. That is deliberate: had the key been left unset,
# Langflow would generate one into the config directory instead, and a
# restore that rebuilt .env by hand would silently produce a deployment whose
# stored credentials no longer decrypt. Set explicitly, the key travels with
# the backup by construction.

backup_langflow() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"

    local pg_user pg_db
    pg_user="$(read_env_value POSTGRES_USER "$install_dir/.env")"
    pg_db="$(read_env_value POSTGRES_DB "$install_dir/.env")"

    if [[ -z "$pg_user" || -z "$pg_db" ]]; then
        print_warn "Could not read POSTGRES_USER/POSTGRES_DB from $install_dir/.env — skipping the dump."
    else
        # stderr to a file, not /dev/null: a discarded error means "pg_dump
        # failed" with the reason — wrong password, database still starting,
        # disk full — thrown away at the one moment it was needed.
        local err_file
        err_file="$(mktemp)"
        if docker exec langflow-db pg_dump -U "$pg_user" "$pg_db" > "$dump_file" 2>"$err_file"; then
            print_info "Database dumped to $dump_file"
        else
            print_warn "pg_dump failed — the archive will contain only a raw (less safe) copy of the db volume."
            [[ -s "$err_file" ]] && sed 's/^/    /' "$err_file" >&2
            # Removed rather than left behind: a truncated dump is worse than
            # no dump. restore_langflow keys off this file existing, and
            # replaying a broken one would drop a good database to load it.
            rm -f "$dump_file"
        fi
        rm -f "$err_file"
    fi

    backup_service_generic "langflow" "$instance" "$install_dir"
}

# ── Why this is not just "psql < db.sql" ────────────────────────────────
# restore_service_generic has ALREADY restored the volumes by the time this
# runs — including langflow_db-data, which it wipes and replaces with the
# archived PGDATA. So the database is not empty when we get here: it is a
# complete copy of itself.
#
# Replaying the dump straight into that gives "relation already exists" and
# duplicate-key errors on every statement — and `psql < file` exits 0 even
# when every statement inside failed, so it would report success. A restore
# that cannot fail is not a restore.
#
# So: drop, recreate empty, replay into that — with ON_ERROR_STOP so a real
# failure is a failure, and --single-transaction so a half-applied dump is
# never left behind. If the drop/create cannot be done, the replay is SKIPPED
# rather than attempted: the restored volume is a coherent state on its own,
# and a partial overlay would turn a working restore into a broken one.
restore_langflow() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "langflow" "$instance" "$install_dir" "$archive"

    [[ -f "$install_dir/db.sql" ]] || return 0

    local pg_user pg_db
    pg_user="$(read_env_value POSTGRES_USER "$install_dir/.env")"
    pg_db="$(read_env_value POSTGRES_DB "$install_dir/.env")"
    if [[ -z "$pg_user" || -z "$pg_db" ]]; then
        print_warn "Could not read POSTGRES_USER/POSTGRES_DB from $install_dir/.env."
        print_warn "The volume restore stands; the dump was NOT replayed."
        return 0
    fi

    # The app must be down before the database can be dropped — an open
    # connection blocks the drop, and a running app would also start writing
    # to the copy we are about to discard.
    (cd "$install_dir" && $(compose_cmd) stop langflow >/dev/null 2>&1) || true
    (cd "$install_dir" && $(compose_cmd) up -d langflow-db) || true

    # Wait for readiness rather than sleeping a guessed number of seconds. A
    # fixed sleep is a bet that the machine restoring is at least as fast as
    # the machine the sleep was written on.
    local i ready=0
    for (( i = 1; i <= 30; i++ )); do
        if docker exec langflow-db pg_isready -h localhost -U "$pg_user" -d "$pg_db" >/dev/null 2>&1; then
            ready=1; break
        fi
        sleep 2
    done
    if (( ! ready )); then
        print_warn "langflow-db did not become ready in 60s. The volume restore stands; the dump was NOT replayed."
        return 0
    fi

    # --force (Postgres 13+) terminates any session still holding the
    # database, so a stray connection cannot silently block the whole restore.
    local err
    err="$(docker exec langflow-db dropdb --force --if-exists -U "$pg_user" "$pg_db" 2>&1)" \
      && err="$(docker exec langflow-db createdb -U "$pg_user" -O "$pg_user" "$pg_db" 2>&1)" \
      || {
        print_warn "Could not recreate database '$pg_db': ${err:-unknown error}"
        print_warn "SKIPPING the dump replay — the restored volume is left intact and usable."
        rm -f "$install_dir/db.sql"
        return 0
      }

    # -o /dev/null as well as -q: a pg_dump script contains real SELECTs
    # (set_config, and setval per sequence) whose RESULT TABLES would
    # otherwise print across the menu on a SUCCESSFUL restore. Errors still
    # reach stderr and the exit status is untouched.
    if docker exec -i langflow-db \
         psql -v ON_ERROR_STOP=1 --single-transaction -q -o /dev/null \
              -U "$pg_user" -d "$pg_db" < "$install_dir/db.sql"; then
        print_info "Database restored from db.sql (dropped, recreated, replayed in one transaction)."
        print_info "LANGFLOW_SECRET_KEY came back with .env in the same archive, so stored credentials still decrypt."
    else
        print_warn "db.sql failed to replay and was rolled back — '$pg_db' is now EMPTY."
        print_warn "Restore an older archive, or reload the dump by hand from the extracted tree."
    fi
    rm -f "$install_dir/db.sql"
}
