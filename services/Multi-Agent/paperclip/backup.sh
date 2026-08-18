# backup.sh (services/Multi-Agent/paperclip) — DB-aware backup/restore hooks.
# Sourced on demand by services.sh's Backup/Restore menu options (see
# load_service_backup_hooks() there) — never exec'd directly, so this file is
# function definitions only, no top-level code.
#
# Paperclip needs this file because its state is split across two places:
#   · Postgres          — accounts, agent teams, goals, tickets, history
#   · ./state (bind)    — instance config under PAPERCLIP_HOME
# The generic volume backup captures the second and would take a raw,
# mid-write copy of the first. A pg_dump is a consistent snapshot; a file copy
# of a running database is a coin toss.
#
# Values are read with read_env_value rather than `grep KEY= .env | cut`,
# which is the convention this repo settled on: cut -d= -f2 truncates any
# value containing '=' — and generate_secret can produce one.

backup_paperclip() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"

    local pg_user pg_db
    pg_user="$(read_env_value POSTGRES_USER "$install_dir/.env")"
    pg_db="$(read_env_value POSTGRES_DB "$install_dir/.env")"

    if [[ -z "$pg_user" || -z "$pg_db" ]]; then
        print_warn "Could not read POSTGRES_USER/POSTGRES_DB from $install_dir/.env — skipping the dump."
    elif docker exec paperclip-db pg_dump -U "$pg_user" "$pg_db" > "$dump_file" 2>/dev/null; then
        print_info "Database dumped to $dump_file"
    else
        print_warn "pg_dump failed — falling back to a raw (less safe) volume copy for the db."
        # Removed rather than left behind: a truncated or empty db.sql is
        # worse than none. restore_paperclip keys off this file existing, so a
        # broken one would be replayed over a good volume restore.
        rm -f "$dump_file"
    fi

    backup_service_generic "paperclip" "$instance" "$install_dir"
}

restore_paperclip() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "paperclip" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        local pg_user pg_db
        pg_user="$(read_env_value POSTGRES_USER "$install_dir/.env")"
        pg_db="$(read_env_value POSTGRES_DB "$install_dir/.env")"

        # Bring up ONLY the database. Starting the app too would let it run
        # migrations against the schema we are about to overwrite.
        (cd "$install_dir" && $(compose_cmd) up -d db) || true

        # Wait for readiness instead of sleeping a guessed number of seconds.
        # A fixed sleep is a bet that the machine restoring is at least as
        # fast as the one that wrote the sleep.
        local i ready=0
        for (( i = 1; i <= 30; i++ )); do
            if docker exec paperclip-db pg_isready -h localhost -U "$pg_user" -d "$pg_db" >/dev/null 2>&1; then
                ready=1; break
            fi
            sleep 2
        done
        (( ready )) || print_warn "paperclip-db did not become ready in 60s — the restore below will probably fail."

        if docker exec -i paperclip-db psql -U "$pg_user" -d "$pg_db" < "$install_dir/db.sql"; then
            print_info "Database restored from db.sql"
        else
            print_warn "Failed to restore db.sql — the volume backup is still in place; restore it manually if needed."
        fi
        rm -f "$install_dir/db.sql"
    fi
}
