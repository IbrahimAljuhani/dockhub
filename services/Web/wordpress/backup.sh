# backup.sh (services/Web/wordpress)
# DB-aware backup/restore override — see services/_template/backup.sh.template
# for why this exists. Adapted (not copied verbatim) because WordPress uses
# MySQL (mysqldump/mysql), not Postgres (pg_dump/psql) like the template's
# default example.
#
# This file must contain ONLY function definitions — services.sh sources it
# on demand, it is never exec'd as its own process.

backup_wordpress() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"

    local db_user db_password db_name
    db_user=$(grep -a '^WORDPRESS_DB_USER=' "$install_dir/.env" | cut -d= -f2)
    db_password=$(grep -a '^WORDPRESS_DB_PASSWORD=' "$install_dir/.env" | cut -d= -f2)
    db_name=$(grep -a '^WORDPRESS_DB_NAME=' "$install_dir/.env" | cut -d= -f2)

    if docker exec wordpress-db mysqldump -u"$db_user" -p"$db_password" "$db_name" > "$dump_file" 2>/dev/null; then
        print_info "Database dumped to $dump_file"
    else
        print_warn "mysqldump failed — falling back to a raw (less safe) volume copy for the db."
        rm -f "$dump_file"
    fi

    # Still capture compose files/.env and the wordpress-data volume (core
    # files, themes, plugins, uploads) the normal way — this only replaces
    # how the db volume itself gets backed up.
    backup_service_generic "wordpress" "$instance" "$install_dir"
}

restore_wordpress() {
    local instance="$1" install_dir="$2" archive="$3"

    restore_service_generic "wordpress" "$instance" "$install_dir" "$archive"

    if [[ -f "$install_dir/db.sql" ]]; then
        local db_user db_password db_name
        db_user=$(grep -a '^WORDPRESS_DB_USER=' "$install_dir/.env" | cut -d= -f2)
        db_password=$(grep -a '^WORDPRESS_DB_PASSWORD=' "$install_dir/.env" | cut -d= -f2)
        db_name=$(grep -a '^WORDPRESS_DB_NAME=' "$install_dir/.env" | cut -d= -f2)
        # db container needs to be up (but the app itself doesn't) for this —
        # services.sh's restore_menu already ran `compose down` before
        # calling this, so bring just the db service back up first.
        (cd "$install_dir" && $(compose_cmd) up -d db) || true
        sleep 5
        docker exec -i wordpress-db mysql -u"$db_user" -p"$db_password" "$db_name" < "$install_dir/db.sql" \
            && print_info "Database restored from db.sql" \
            || print_warn "Failed to restore db.sql — restore the volume backup manually if needed."
        rm -f "$install_dir/db.sql"
    fi
}
