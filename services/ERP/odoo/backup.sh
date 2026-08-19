# backup.sh (services/ERP/odoo) — DB-aware backup/restore hooks.
# Sourced on demand by services.sh's Backup/Restore menu options — never
# exec'd directly, so this file is function definitions only, no top-level
# code. See services/_template/backup.sh.template for why this is separate
# from deploy.sh.
#
# Odoo is multi-instance, so $1 (instance) is always non-empty here — the
# db container is odoo-<instance>-db (see docker-compose.yml). Uses
# pg_dumpall (not pg_dump of a single database) because the actual business
# database name is chosen by the user later, inside Odoo's own
# /web/database/manager, not at deploy time — ODOO_DB_NAME in .env is only
# informational for deployments made after this was added; older
# deployments won't have it, so pg_dumpall (dumps every DB + roles in the
# cluster) is the one approach that works unconditionally.
#
# ─────────────────────────────────────────────────────────────────────────
# WHY THIS RESTORE DIFFERS FROM EVERY OTHER ONE IN THE REPO
#
# The bug is the same as everywhere else: restore_service_generic replaces
# the database volume unconditionally, so the cluster is already a complete
# copy of itself before the dump is replayed. Replaying on top errors on
# every object, and psql exits 0 anyway — success printed over a no-op.
#
# But the FIX cannot be the one used for single-database services, for three
# reasons that are properties of a cluster dump, not preferences:
#
#   1. `--single-transaction` is IMPOSSIBLE. A pg_dumpall script contains
#      CREATE DATABASE, and PostgreSQL forbids that inside a transaction
#      block. Copying the paperclip pattern here would fail immediately.
#
#   2. `ON_ERROR_STOP=1` is IMPOSSIBLE for the same kind of reason. The dump
#      re-creates ROLES, and roles are cluster-wide: they survive dropping
#      databases, so `CREATE ROLE odoo` hits an existing role and errors.
#      That error is benign and expected — stopping on it would abort a
#      restore that was about to succeed.
#
#   3. There is no `dropdb` for a cluster. You cannot drop the thing you are
#      connected to, so the unit of work is each database inside it.
#
# Hence: enumerate the real databases, drop those, replay, and then JUDGE
# THE OUTPUT instead of trusting the exit status — classifying the benign
# "role already exists" apart from everything else. It is more code than the
# others because the situation genuinely is different, not because it was
# written more carefully.
# ─────────────────────────────────────────────────────────────────────────

backup_odoo() {
    local instance="$1" install_dir="$2"
    local dump_file="$install_dir/db.sql"
    local db_container="odoo-${instance}-db"

    local pg_user
    pg_user="$(read_env_value POSTGRES_USER "$install_dir/.env")"
    if [[ -z "$pg_user" ]]; then
        print_warn "Could not read POSTGRES_USER from $install_dir/.env — skipping the dump."
        backup_service_generic "odoo" "$instance" "$install_dir"
        return 0
    fi

    # stderr captured, not discarded — the reason a dump failed is only ever
    # printed once, at the moment it fails.
    local err_file
    err_file="$(mktemp)"
    if docker exec "$db_container" pg_dumpall -U "$pg_user" > "$dump_file" 2>"$err_file"; then
        print_info "Database cluster dumped to $dump_file"
    else
        print_warn "pg_dumpall failed — the archive will hold only a raw (less safe) copy of the db volume."
        [[ -s "$err_file" ]] && sed 's/^/    /' "$err_file" >&2
        rm -f "$dump_file"
    fi
    rm -f "$err_file"

    backup_service_generic "odoo" "$instance" "$install_dir"
}

restore_odoo() {
    local instance="$1" install_dir="$2" archive="$3"
    local db_container="odoo-${instance}-db"

    restore_service_generic "odoo" "$instance" "$install_dir" "$archive"

    [[ -s "$install_dir/db.sql" ]] || {
        # Absent OR empty. An empty dump is worse than none: it would make the
        # code below drop every database and then load nothing.
        [[ -f "$install_dir/db.sql" ]] && {
            print_warn "db.sql is empty — the volume restore stands, nothing was replayed."
            rm -f "$install_dir/db.sql"
        }
        return 0
    }

    local pg_user
    pg_user="$(read_env_value POSTGRES_USER "$install_dir/.env")"
    if [[ -z "$pg_user" ]]; then
        print_warn "Could not read POSTGRES_USER from $install_dir/.env."
        print_warn "The volume restore stands; the dump was NOT replayed."
        return 0
    fi

    (cd "$install_dir" && $(compose_cmd) up -d db) || true

    local _i _ready=0
    for (( _i = 1; _i <= 30; _i++ )); do
        if docker exec "$db_container" pg_isready -h localhost -U "$pg_user" >/dev/null 2>&1; then
            _ready=1; break
        fi
        sleep 2
    done
    if (( ! _ready )); then
        print_warn "$db_container did not become ready in 60s. Volume restore stands; dump NOT replayed."
        return 0
    fi

    # Every real database in the cluster: templates excluded because they
    # cannot be dropped, and 'postgres' excluded because it is the one we
    # connect through to do the dropping.
    local _dbs
    _dbs="$(docker exec "$db_container" psql -U "$pg_user" -d postgres -tAc \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres'" 2>/dev/null)"

    local _db _drop_failed=0
    for _db in $_dbs; do
        docker exec "$db_container" dropdb --force --if-exists -U "$pg_user" "$_db" >/dev/null 2>&1 \
            || { print_warn "Could not drop database '$_db'."; _drop_failed=1; }
    done
    if (( _drop_failed )); then
        print_warn "SKIPPING the replay — a half-dropped cluster plus a partial reload is"
        print_warn "worse than the volume restore already in place, which is left intact."
        rm -f "$install_dir/db.sql"
        return 0
    fi

    # No --single-transaction and no ON_ERROR_STOP — see the header. The exit
    # status of psql is therefore not evidence of anything; the OUTPUT is.
    local _log
    _log="$(mktemp)"
    docker exec -i "$db_container" psql -U "$pg_user" -d postgres \
        < "$install_dir/db.sql" > "$_log" 2>&1

    # "role ... already exists" is expected: roles are cluster-wide and
    # survived the per-database drops above. Anything else is a real failure.
    local _real
    _real="$(grep -E '^(psql:)?.*ERROR:' "$_log" | grep -vE 'role ".*" already exists' || true)"

    if [[ -z "$_real" ]]; then
        local _n
        _n="$(docker exec "$db_container" psql -U "$pg_user" -d postgres -tAc \
              "SELECT count(*) FROM pg_database WHERE datistemplate = false AND datname <> 'postgres'" 2>/dev/null)"
        print_info "Database cluster restored from db.sql — ${_n:-?} database(s) reloaded."
    else
        print_warn "The cluster reload reported errors that are NOT the expected role conflicts:"
        echo "$_real" | head -15 | sed 's/^/    /' >&2
        print_warn "The databases were dropped before the reload, so Odoo may now be"
        print_warn "incomplete. The archive is still at: $archive"
    fi
    rm -f "$_log" "$install_dir/db.sql"
}
