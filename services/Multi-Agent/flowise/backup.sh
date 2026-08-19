# backup.sh (services/Multi-Agent/flowise) — DB-aware backup/restore hooks.
# Sourced on demand by services.sh's Backup/Restore menu options (see
# load_service_backup_hooks() there) — never exec'd directly, so this file is
# function definitions only, no top-level code.
#
# This file did not exist while Flowise ran on SQLite, and the README said so
# in as many words: everything lived under ./data, so the generic install-tree
# backup captured all of it. Moving to Postgres (see docker-compose.yml,
# note 3) split the state across two places:
#   · Postgres        — flows, chat history, accounts, API keys, variables
#   · ./data (bind)   — the ENCRYPTION KEY, uploads, logs
# The generic backup captures the second and would take a raw, mid-write copy
# of the first. A pg_dump is a consistent snapshot; a file copy of a running
# database is a coin toss.
#
# ── The pairing that matters more here than in most services ────────────
# Flowise encrypts every stored model-provider credential with the key file
# under ./data, and the CIPHERTEXT lives in Postgres. Restoring one without
# the other leaves credentials that decrypt to nothing. Both are inside the
# same archive on purpose — do not restore a database dump against a
# different install's data directory.

backup_flowise() {
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
        if docker exec flowise-db pg_dump -U "$pg_user" "$pg_db" > "$dump_file" 2>"$err_file"; then
            print_info "Database dumped to $dump_file"
        else
            print_warn "pg_dump failed — the archive will contain only a raw (less safe) copy of the db volume."
            [[ -s "$err_file" ]] && sed 's/^/    /' "$err_file" >&2
            # Removed rather than left behind: a truncated dump is worse than
            # no dump. restore_flowise keys off this file existing, and
            # replaying a broken one would drop a good database to load it.
            rm -f "$dump_file"
        fi
        rm -f "$err_file"
    fi

    backup_service_generic "flowise" "$instance" "$install_dir"
}

# ── Why this is not just "psql < db.sql" ────────────────────────────────
# restore_service_generic has ALREADY restored the volumes by the time this
# runs — including flowise_db-data, which it wipes and replaces with the
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
restore_flowise() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "flowise" "$instance" "$install_dir" "$archive"

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
    (cd "$install_dir" && $(compose_cmd) stop flowise >/dev/null 2>&1) || true
    (cd "$install_dir" && $(compose_cmd) up -d flowise-db) || true

    # Wait for readiness rather than sleeping a guessed number of seconds. A
    # fixed sleep is a bet that the machine restoring is at least as fast as
    # the machine the sleep was written on.
    local i ready=0
    for (( i = 1; i <= 30; i++ )); do
        if docker exec flowise-db pg_isready -h localhost -U "$pg_user" -d "$pg_db" >/dev/null 2>&1; then
            ready=1; break
        fi
        sleep 2
    done
    if (( ! ready )); then
        print_warn "flowise-db did not become ready in 60s. The volume restore stands; the dump was NOT replayed."
        return 0
    fi

    # --force (Postgres 13+) terminates any session still holding the
    # database, so a stray connection cannot silently block the whole restore.
    local err
    err="$(docker exec flowise-db dropdb --force --if-exists -U "$pg_user" "$pg_db" 2>&1)" \
      && err="$(docker exec flowise-db createdb -U "$pg_user" -O "$pg_user" "$pg_db" 2>&1)" \
      || {
        print_warn "Could not recreate database '$pg_db': ${err:-unknown error}"
        print_warn "SKIPPING the dump replay — the restored volume is left intact and usable."
        rm -f "$install_dir/db.sql"
        return 0
      }

    if docker exec -i flowise-db \
         psql -v ON_ERROR_STOP=1 --single-transaction -q -o /dev/null \
              -U "$pg_user" -d "$pg_db" < "$install_dir/db.sql"; then
        print_info "Database restored from db.sql (dropped, recreated, replayed in one transaction)."
        print_info "The credential encryption key came back with ./data in the same archive."
    else
        print_warn "db.sql failed to replay and was rolled back — '$pg_db' is now EMPTY."
        print_warn "Restore an older archive, or reload the dump by hand from the extracted tree."
    fi
    rm -f "$install_dir/db.sql"
}
