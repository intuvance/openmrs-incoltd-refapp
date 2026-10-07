#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot database initialisation job for the Intuvance OpenMRS O3 distribution.
#
# Runs as the `db-init` compose service: after `db` is healthy, before `backend`
# starts. It is safe to run repeatedly.
#
#   0. GATE     Decide whether the database still holds the terminology the seed
#               installed. If it does, nothing below runs at all.
#   1. SEED     Restore `seed.sql` from the pre-populated seed image, so CIEL,
#               the core concepts, the core concept sets and the core Reference
#               Application metadata already exist before OpenMRS starts. This is
#               what removes the need for a multi-hour OCL terminology download
#               during first startup. It is a FALLBACK: on a healthy install it
#               never runs (see the gate below).
#   2. ARCHIVE  Copy the concept reference mappings into a durable archive table.
#               The mappings are what order entry, medication workflows and FHIR
#               translation depend on, so they are kept recoverable even if
#               something else later removes them. `INSERT IGNORE`, so re-running
#               can never overwrite a good archive with a degraded live table.
#   3. ROTATE   Replace the seed's database password with the deployment secret
#               and create a least-privilege account for OpenMRS.
#
# WHY THE RESTORE IS A FALLBACK, NOT A STEP
#   The distro now ships the Intuvance fork of the Initializer
#   (io.github.intuvance:initializer-omod, pinned in distro/pom.xml), which does
#   not destroy terminology on first boot the way upstream 2.12.0 does. Upstream
#   calls clear() on the Hibernate collections of every concept it loads from a
#   content package and then re-adds only what the CSV column declares; this
#   distro's concepts.csv declares no mappings column values, so 18,882 concept
#   reference mappings were deleted on first boot and never recreated, silently
#   breaking drug and lab order entry, medication workflows and FHIR concept-code
#   lookups.
#
#   With the fork, a restored database stays correct. So the restore only runs
#   when the gate cannot find the terminology it installed, which is what makes
#   `docker compose up` cheap and repeatable on an install that already works --
#   the dump is 15 MB and restoring it costs minutes of database time.
#
#   The gate is a containment measure, not decoration. It is what keeps a
#   half-loaded or hand-edited database from being silently accepted, and it is
#   the reason a fresh volume and a long-lived volume converge on the same
#   terminology.
#
# THE GATE'S TWO REASONS TO RESTORE
#   * Drift.   The seed's concepts are missing, concept reference mappings were
#              lost, mappings point at concepts that no longer exist, the concept
#              set flag is out of step with the concept_set rows, or fewer than
#              three concept map types survive. Any of these means drug and lab
#              orders cannot be placed, so the dump is replayed.
#   * New seed. The seed dump's checksum no longer matches the one recorded when
#              it was applied, so the image carries terminology this database has
#              never seen. A changed seed means a re-restore even when the
#              database is otherwise intact, which is what keeps two fresh builds
#              of the same commit in agreement.
#
#   Set OMRS_DB_RESTORE_ON_DRIFT=false to downgrade drift from "restore" to
#   "warn and continue". That is for an instance whose terminology has been
#   deliberately edited by hand; on any normal install the restore is correct.
#
# The demo clinical data is *not* purged here: the published seed image is already
# sanitised at build time by .github/workflows/build-db-seed.yml, which runs
# deployment/db/purge-demo-data.sql against the container before exporting the
# dump. Shipping a clean artifact is what keeps this job free of destructive SQL.
# Set OMRS_DB_PURGE_AFTER_SEED=true only if you have deliberately pointed
# OMRS_DB_SEED_IMAGE at a raw, unsanitised image.
#
# IDEMPOTENCY / DATA SAFETY
#   A marker row in `deployment_state` records that initialisation completed, and
#   `openmrs_seed_concept_manifest` records the UUID of every concept the seed
#   installed. A later run re-checks both; if the terminology is still whole the
#   script logs and exits 0 without touching anything. So `docker compose up`,
#   `docker compose restart` and repeated `up` are all safe, and this job cannot
#   overwrite a database that is intact. There is no DROP, TRUNCATE or
#   database-level reset anywhere in this file.
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
SEED_ENABLED="${OMRS_DB_SEED_ENABLED:-true}"
RESTORE_ON_DRIFT="${OMRS_DB_RESTORE_ON_DRIFT:-true}"

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
SEED_SQL="${OMRS_DB_SEED_FILE:-${SEED_DIR}/seed.sql}"

# Schema tables this script owns. Created unconditionally and idempotently, so
# the gate below can ask its questions before anything else has run.
ensure_state_tables() {
    "${TARGET_MYSQL[@]}" "${DB_NAME}" <<SQL
CREATE TABLE IF NOT EXISTS deployment_state (
    name       VARCHAR(64)  NOT NULL,
    value      VARCHAR(255) NOT NULL,
    created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS openmrs_seed_concept_manifest (
    uuid CHAR(38) NOT NULL,
    PRIMARY KEY (uuid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL
}

state_get() {
    "${TARGET_MYSQL[@]}" -N -B -e "
        SELECT IFNULL((SELECT value FROM \`${DB_NAME}\`.deployment_state WHERE name = '${1}'), '');" \
        2>/dev/null || echo ""
}

# --- wait for the database --------------------------------------------------
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

# --- 0. GATE ----------------------------------------------------------------
# The schema may not exist yet on a first run; asking is cheap either way.
if "${TARGET_MYSQL[@]}" "${DB_NAME}" -e "SELECT 1" >/dev/null 2>&1; then
    ensure_state_tables
else
    "${TARGET_MYSQL[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4;" \
        || die "could not create the ${DB_NAME} schema"
    ensure_state_tables
fi

MARKER="$(state_get db_initialised)"
SEED_FINGERPRINT_RECORDED="$(state_get seed_fingerprint)"

# Checksum of the dump this image ships. Compared against the recorded one so a
# rebuilt seed forces a re-restore even when the database looks intact: two fresh
# builds of the same commit then converge, which is the property that makes a
# wipe-and-redeploy reproducible rather than merely repeatable.
seed_fingerprint() {
    if [ -f "${SEED_SQL}" ] && [ ! -d "${SEED_SQL}" ]; then
        sha256sum "${SEED_SQL}" | cut -d' ' -f1
    else
        echo ""
    fi
}

# Emits the integrity report on stdout: one line per failed check, and nothing at
# all when the terminology is whole. Returning lines rather than a code lets the
# operator see which specific thing is wrong instead of a bare "failed".
integrity_report() {
    "${TARGET_MYSQL[@]}" -N -B "${DB_NAME}" <<'SQL'
SELECT CONCAT('concepts missing from the seed: ', (
    SELECT COUNT(*) FROM openmrs_seed_concept_manifest m
     WHERE NOT EXISTS (SELECT 1 FROM concept c WHERE c.uuid = m.uuid)))
HAVING (SELECT COUNT(*) FROM openmrs_seed_concept_manifest m
        WHERE NOT EXISTS (SELECT 1 FROM concept c WHERE c.uuid = m.uuid)) > 0
UNION ALL
SELECT CONCAT('concept reference mappings lost: archive holds ', (
    SELECT COUNT(*) FROM openmrs_concept_map_archive),
    ' but only ', (SELECT COUNT(*) FROM concept_reference_map),
    ' remain -- the Initializer destroyed them')
HAVING (SELECT COUNT(*) FROM openmrs_concept_map_archive) > (SELECT COUNT(*) FROM concept_reference_map)
UNION ALL
SELECT CONCAT('dangling concept reference mappings: ', (
    SELECT COUNT(*) FROM concept_reference_map rm
     WHERE NOT EXISTS (SELECT 1 FROM concept c WHERE c.concept_id = rm.concept_id)))
HAVING (SELECT COUNT(*) FROM concept_reference_map rm
        WHERE NOT EXISTS (SELECT 1 FROM concept c WHERE c.concept_id = rm.concept_id)) > 0
UNION ALL
SELECT CONCAT('concept map types surviving: ', (SELECT COUNT(*) FROM concept_map_type),
    ' -- fewer than three means the terminology was replaced, not merely thinned')
HAVING (SELECT COUNT(*) FROM concept_map_type) < 3
UNION ALL
SELECT CONCAT('concept_set rows disagree with concept.is_set: ', (
    SELECT COUNT(*) FROM concept c
     WHERE c.is_set = 0
       AND EXISTS (SELECT 1 FROM concept_set cs WHERE cs.concept_set = c.concept_id)))
HAVING (SELECT COUNT(*) FROM concept c
        WHERE c.is_set = 0
          AND EXISTS (SELECT 1 FROM concept_set cs WHERE cs.concept_set = c.concept_id)) > 0;
SQL
}

should_restore=1
restore_reason="no previous initialisation recorded"

if [ "${MARKER}" = "true" ]; then
    if [ "${SEED_ENABLED}" != "true" ]; then
        # Nothing to restore against. This install was built from content
        # packages at first startup, so the manifest is empty and there is no
        # dump to replay. Leave it exactly as the marker path always has.
        log "database already initialised and OMRS_DB_SEED_ENABLED=${SEED_ENABLED}; nothing to do"
        exit 0
    fi

    if [ ! -f "${SEED_SQL}" ] || [ -d "${SEED_SQL}" ]; then
        die "database is already initialised but no seed dump is present at ${SEED_SQL}.
       Concepts cannot be verified, and this job will not skip the restore on an
       unverified database. Mount the seed dump, or set OMRS_DB_SEED_ENABLED=false
       to accept the database as it stands."
    fi

    SEED_FINGERPRINT_CURRENT="$(seed_fingerprint)"
    # An empty recorded fingerprint means this database was initialised by a version
    # of this script that did not record one. That is not evidence that the seed
    # changed, so fall through to the integrity report rather than forcing a
    # destructive re-restore on an install that is otherwise healthy.
    if [ -n "${SEED_FINGERPRINT_RECORDED}" ] \
        && [ -n "${SEED_FINGERPRINT_CURRENT}" ] \
        && [ "${SEED_FINGERPRINT_RECORDED}" != "${SEED_FINGERPRINT_CURRENT}" ]; then
        restore_reason="the seed dump changed (recorded ${SEED_FINGERPRINT_RECORDED}, shipped ${SEED_FINGERPRINT_CURRENT})"
    else
        # concept_map_type and concept_reference_map only exist once the schema has
        # been created, which on a previously-initialised database it always has.
        REPORT="$(integrity_report || true)"
        if [ -z "${REPORT}" ]; then
            log "terminology verified intact; skipping the dump restore"
            exit 0
        fi
        if [ "${RESTORE_ON_DRIFT}" != "true" ]; then
            log "WARNING: terminology has drifted and OMRS_DB_RESTORE_ON_DRIFT=false, so continuing without a restore:"
            echo "${REPORT}" | sed 's/^/[db-init] WARNING:   /'
            log "WARNING: drug and lab order entry will fail until this is resolved"
            exit 0
        fi
        restore_reason="terminology drift:
$(echo "${REPORT}" | sed 's/^/  - /')"
    fi

    log "restore required: ${restore_reason}"
else
    log "first initialisation of this database"
fi

# --- 1. SEED ----------------------------------------------------------------
if [ "${SEED_ENABLED}" = "true" ]; then
    if [ ! -s "${SEED_SQL}" ] || [ -d "${SEED_SQL}" ]; then
        die "no seed dump at ${SEED_SQL}. Check OMRS_DB_SEED_IMAGE, or set
       OMRS_DB_SEED_ENABLED=false to build the database from the official
       Reference Application content package at first startup instead."
    fi

    # A restore rewrites every table in the schema, so it cannot run while anything
    # else is connected. In the normal flow this is guaranteed by the compose
    # topology -- backend depends_on db-init completing -- but a restore triggered
    # by drift is exactly the situation an operator is most likely to run by hand
    # with `docker compose run db-init` while the backend is still up, and the
    # symptom without this check is a bare "Lock wait timeout exceeded" part-way
    # through the import, leaving the database half-restored.
    APP_CONNECTIONS=$("${TARGET_MYSQL[@]}" -N -B -e "
        SELECT COUNT(*) FROM information_schema.PROCESSLIST
         WHERE DB = '${DB_NAME}'
           AND USER <> 'root'
           AND USER <> 'system user'
           AND ID <> CONNECTION_ID();" 2>/dev/null || echo 0)
    if [ "${APP_CONNECTIONS}" -gt 0 ] && [ "${OMRS_DB_FORCE_RESTORE:-false}" != "true" ]; then
        die "${APP_CONNECTIONS} connection(s) other than this job are attached to ${DB_NAME}.
       A restore cannot run alongside them and would otherwise fail part-way through
       with a lock timeout, leaving the database half-written. Stop the backend
       first:

         docker compose stop backend
         docker compose run --rm db-init
         docker compose up -d backend

       Set OMRS_DB_FORCE_RESTORE=true to override, which is only safe if you are
       certain nothing else is using this database."
    fi

    log "restoring the pre-populated database from ${SEED_SQL}"
    log "this stream is large; several minutes of apparent inactivity is normal"

    set +e
    "${TARGET_MYSQL[@]}" "${DB_NAME}" < "${SEED_SQL}"
    RESTORE_RC=$?
    set -e
    [ "${RESTORE_RC}" -eq 0 ] || die "restoring the seed dump failed (rc=${RESTORE_RC})"
    log "seed restored"

    # Record which concepts this restore installed. The gate compares against
    # this on every later run, so it is written here and only here -- it describes
    # the dump, not whatever the live database happens to contain afterwards.
    # Concepts added by an administrator afterwards are deliberately not recorded,
    # so they never become a reason to restore.
    log "recording the seed's concept manifest"
    "${TARGET_MYSQL[@]}" "${DB_NAME}" <<SQL
INSERT IGNORE INTO openmrs_seed_concept_manifest (uuid) SELECT uuid FROM concept;
SQL

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

# --- 2. ARCHIVE the concept reference mappings --------------------------------
# A durable copy of the mappings that drug orders, lab orders, medication
# workflows, order-entry concept search and FHIR translation all resolve concepts
# by. Kept as a recovery path for an install that predates the fixed Initializer,
# whose mappings are already gone, and for any future regression.
#
# Idempotent, and `INSERT IGNORE`, so re-running never overwrites a good archive
# with a degraded live table.
log "archiving the concept reference mappings"
"${TARGET_MYSQL[@]}" "${DB_NAME}" < "${OMRS_DB_REPAIR_SQL:-/usr/local/share/concept-map-repair.sql}" \
    || die "archiving the concept reference mappings failed"
ARCHIVED=$("${TARGET_MYSQL[@]}" -N -B -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.openmrs_concept_map_archive;" \
    2>/dev/null || echo 0)
log "archived ${ARCHIVED} concept reference mappings"

# --- 3. ROTATE credentials --------------------------------------------------
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
# Only written once every phase above succeeded, so its presence means the
# database is complete and the gate may skip the restore next time.
"${TARGET_MYSQL[@]}" "${DB_NAME}" <<SQL
INSERT INTO deployment_state (name, value)
VALUES ('db_initialised', 'true')
ON DUPLICATE KEY UPDATE value = VALUES(value);

INSERT INTO deployment_state (name, value)
VALUES ('seed_fingerprint', '$(esc "$(seed_fingerprint)")')
ON DUPLICATE KEY UPDATE value = VALUES(value);
SQL

log "database initialisation complete"
