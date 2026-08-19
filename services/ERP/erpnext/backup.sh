# backup.sh (services/ERP/erpnext)
# DB-aware backup/restore override — see services/_template/backup.sh.template
# for why this exists. ERPNext keeps everything that matters in two places:
# the MariaDB database, and the `sites` volume (site config, encryption key,
# uploaded files, custom apps). The generic volume copy handles the second
# correctly but would raw-copy live MariaDB data files for the first, which
# can produce a subtly corrupt, unrestorable dump.
#
# Two ERPNext-specific wrinkles drive the choices below:
#   1. --all-databases, not a named database. Frappe names a site's database
#      after a hash it generates at creation time (something like _a1b2c3...),
#      so there is no stable name to dump. It also creates a dedicated DB user
#      per site, and those live in the `mysql` system database — dumping only
#      the site's own database would restore the data but not the account
#      that's allowed to read it.
#   2. MariaDB 11 renamed the client binaries (mysqldump -> mariadb-dump).
#      The old names still exist as deprecated symlinks in 11.8, but they're
#      on their way out, so each command below tries the new name first.
#
# This file must contain ONLY function definitions — services.sh sources it
# on demand, it is never exec'd as its own process.

# Picks whichever client binary this MariaDB image actually ships.
# $1 = new-style name, $2 = legacy name. Prints the one that exists.
_erpnext_db_bin() {
    if docker exec erpnext-db sh -c "command -v $1" >/dev/null 2>&1; then
        echo "$1"
    else
        echo "$2"
    fi
}

backup_erpnext() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local _derr; _derr="$(mktemp)"

    local db_password dump_bin
    db_password=$(read_env_value "DB_PASSWORD" "$install_dir/.env")
    dump_bin=$(_erpnext_db_bin mariadb-dump mysqldump)

    # --single-transaction gives a consistent snapshot without locking the
    # whole server, which matters here because ERPNext's own scheduler and
    # queue workers keep writing throughout the backup. --events and
    # --routines are included because Frappe installs both.
    if docker exec erpnext-db "$dump_bin" -uroot -p"$db_password" \
        --all-databases --single-transaction --events --routines > "$dump_file" 2>"$_derr"; then
        print_info "Database dumped to $dump_file"
    else
        print_warn "$dump_bin failed — falling back to a raw (less safe) volume copy for the db."
        [[ -s "$_derr" ]] && sed "s/^/    /" "$_derr" >&2
        rm -f "$dump_file"
    fi

    # Still capture the compose files, .env and the `sites` volume the normal
    # way — this only replaces how the db itself gets captured.
    rm -f "$_derr"
    backup_service_generic "erpnext" "$instance" "$install_dir"
}

restore_erpnext() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "erpnext" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        local db_password client_bin
        db_password=$(read_env_value "DB_PASSWORD" "$install_dir/.env")
        # The db container needs to be up (the app doesn't) — services.sh's
        # restore_menu ran `compose down` before calling this, so bring just
        # the db service back first and wait for it to accept connections.
        (cd "$install_dir" && $(compose_cmd) up -d db) || true
        client_bin=$(_erpnext_db_bin mariadb mysql)
        local waited=0
        while (( waited < 60 )); do
            docker exec erpnext-db "$client_bin" -uroot -p"$db_password" -e 'SELECT 1' >/dev/null 2>&1 && break
            sleep 3
            waited=$(( waited + 3 ))
        done

        if docker exec -i erpnext-db "$client_bin" -uroot -p"$db_password" < "$install_dir/db.sql"; then
            print_info "Database restored from db.sql"
            rm -f "$install_dir/db.sql"
        else
            print_warn "Failed to restore db.sql — the file has been left at $install_dir/db.sql so you can retry by hand."
        fi

        # --all-databases includes the `mysql` system database, so the grant
        # tables were just overwritten wholesale. Without this the server
        # keeps serving the pre-restore permissions until it restarts, and
        # the site's own DB user appears not to exist.
        docker exec erpnext-db "$client_bin" -uroot -p"$db_password" -e 'FLUSH PRIVILEGES' >/dev/null 2>&1 \
            || print_warn "Could not flush privileges — restart the erpnext-db container before starting the rest of the stack."
    fi
}
