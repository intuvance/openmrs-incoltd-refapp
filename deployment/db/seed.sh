#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot database initialisation job for the Intuvance OpenMRS O3 distribution.
#
# Runs as the `db-init` compose service: after `db` is healthy, before `backend`
# starts. It is safe to run repeatedly.
#
#   1. SEED     Restore `seed.sql` from the pre-populated seed image into the
#               database, so CIEL, the core concepts, the core concept sets and
#               the core Reference Application metadata already exist before
#               OpenMRS starts. This is what removes the need for a multi-hour OCL
#               terminology download during first startup.
#   2. ROTATE   Replace the seed's database password with the deployment secret
#               and create a least-privilege account for OpenMRS.
#
# The demo clinical data is *not* purged here: the published seed image is already
# sanitised at build time by .github/workflows/build-db-seed.yml, which runs
# deployment/db/purge-demo-data.sql against the container before exporting the
# dump. Shipping a clean artifact is what keeps this job free of destructive SQL.
# Set OMRS_DB_PURGE_AFTER_SEED=true only if you have deliberately pointed
# OMRS_DB_SEED_IMAGE at a raw, unsanitised image.
#
# IDEMPOTENCY / DATA SAFETY
#   A marker row in `deployment_state` records that initialisation completed. If
#   it is present, this script logs and exits 0 without touching anything. So
#   `docker compose up`, `docker compose restart` and repeated `up` are all safe,
#   and this job can never run against a database that is already in use. There is
#   no DROP, TRUNCATE or database-level reset anywhere in this file.
#
# Exit codes
#   0  nothing to do, or initialisation completed successfully
#   1  initialisation failed (the backend then does not start)
# ---------------------------------------------------------------------------
set -euo pipefail

log() { echo "[db-init] $*"; }
die() { echo "[db-init] ERROR: $*" >&2; exit 1; }

DB_HOST="${OMRS_DB_HOST:-db}"
DB_PORT="${OMRS_DB_PORT:-3306}"
DB_NAME="${OMRS_DB_NAME:-openmrs}"
SEED_DIR="${OMRS_DB_SEED_DIR:-/openmrs-seed}"

# Credentials the OpenMRS backend will use. Supplied by the deployment, never
# committed to this repository.
APP_USER="${OMRS_DB_USER:?OMRS_DB_USER must be set}"
APP_PASSWORD="${OMRS_DB_PASSWORD:?OMRS_DB_PASSWORD must be set}"
ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD must be set}"

# The password baked into the seed image. It is a property of a public image, not
# a secret, and exists here only so it can be revoked by the rotation step.
SEED_PASSWORD="${OMRS_DB_SEED_PASSWORD:-openmrs}"
SEED_USER="${OMRS_DB_SEED_USER:-openmrs}"

TARGET_MYSQL=(mariadb --protocol=tcp -h "${DB_HOST}" -P "${DB_PORT}" -u root "-p${ROOT_PASSWORD}")

log "waiting for ${DB_HOST}:${DB_PORT}"
for _ in $(seq 1 120); do
    if "${TARGET_MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1; then
        log "database is up"
        break
    fi
    sleep 2
done
"${TARGET_MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1 \
    || die "database at ${DB_HOST}:${DB_PORT} never became available"

# --- idempotency gate -------------------------------------------------------
# Guard the whole job on a single query. If the marker table exists and the
# marker row is present, we are looking at an already-initialised database.
ALREADY_INITIALISED=$("${TARGET_MYSQL[@]}" -N -B -e "
    SELECT IFNULL((
        SELECT COUNT(*)
          FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = '${DB_NAME}' AND TABLE_NAME = 'deployment_state'
    ), 0);" 2>/dev/null || echo 0)

if [ "${ALREADY_INITIALISED}" = "1" ]; then
    MARKER=$("${TARGET_MYSQL[@]}" -N -B -e "
        SELECT COUNT(*) FROM \`${DB_NAME}\`.deployment_state
         WHERE name = 'db_initialised';" 2>/dev/null || echo 0)
    if [ "${MARKER}" = "1" ]; then
        log "database already initialised; skipping seed and credential rotation"
        exit 0
    fi
fi

# --- 1. SEED ----------------------------------------------------------------
if [ "${OMRS_DB_SEED_ENABLED:-true}" = "true" ]; then
    SEED_SQL="${OMRS_DB_SEED_FILE:-${SEED_DIR}/seed.sql}"

    if [ ! -s "${SEED_SQL}" ] || [ -d "${SEED_SQL}" ]; then
        die "no seed dump at ${SEED_SQL}. Check OMRS_DB_SEED_IMAGE, or set
       OMRS_DB_SEED_ENABLED=false to build the database from the official
       Reference Application content package at first startup instead."
    fi

    log "restoring the pre-populated database from ${SEED_SQL}"
    log "this stream is large; several minutes of apparent inactivity is normal"

    set +e
    "${TARGET_MYSQL[@]}" "${DB_NAME}" < "${SEED_SQL}"
    RESTORE_RC=$?
    set -e
    [ "${RESTORE_RC}" -eq 0 ] || die "restoring the seed dump failed (rc=${RESTORE_RC})"
    log "seed restored"

    if [ "${OMRS_DB_PURGE_AFTER_SEED:-false}" = "true" ]; then
        log "OMRS_DB_PURGE_AFTER_SEED=true: purging demo clinical data"
        "${TARGET_MYSQL[@]}" "${DB_NAME}" < "${OMRS_DB_PURGE_SQL:-/usr/local/share/purge-demo-data.sql}"
        log "demo data purge complete"
    fi
else
    log "OMRS_DB_SEED_ENABLED=${OMRS_DB_SEED_ENABLED}; skipping the pre-populated seed."
    log "Terminology and core metadata will be installed by the Initializer from"
    log "the official Reference Application content package at first startup."
fi

# --- 2. ROTATE credentials --------------------------------------------------
# The seed image ships a fixed, publicly known database password. Revoke it, then
# create a least-privilege account scoped to this schema for OpenMRS. Liquibase
# needs DDL rights because OMRS_CONFIG_AUTO_UPDATE_DATABASE is enabled.
log "rotating database credentials to the deployment secrets"

esc() { printf "%s" "$1" | sed "s/'/''/g"; }

"${TARGET_MYSQL[@]}" <<SQL
DROP USER IF EXISTS '${SEED_USER}'@'%';
DROP USER IF EXISTS '${APP_USER}'@'%';

CREATE USER '${APP_USER}'@'%' IDENTIFIED BY '$(esc "${APP_PASSWORD}")';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP,
      CREATE TEMPORARY TABLES, LOCK TABLES, REFERENCES, EXECUTE,
      CREATE VIEW, SHOW VIEW, TRIGGER
  ON \`${DB_NAME}\`.* TO '${APP_USER}'@'%';

ALTER USER 'root'@'localhost' IDENTIFIED BY '$(esc "${ROOT_PASSWORD}")';
FLUSH PRIVILEGES;
SQL
log "credentials rotated"

# --- marker -----------------------------------------------------------------
"${TARGET_MYSQL[@]}" "${DB_NAME}" <<SQL
CREATE TABLE IF NOT EXISTS deployment_state (
    name       VARCHAR(64)  NOT NULL,
    value      VARCHAR(255) NOT NULL,
    created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO deployment_state (name, value)
VALUES ('db_initialised', 'true')
ON DUPLICATE KEY UPDATE value = VALUES(value);
SQL

log "database initialisation complete"
