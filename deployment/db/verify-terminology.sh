#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot terminology integrity check and repair.
#
# Runs as the `db-verify` compose service: after `backend` reports healthy, so it
# always observes the database in its *post*-startup state, which is the state
# that matters. Safe to run repeatedly.
#
# Why it exists
#   `openmrs-module-initializer` deletes the pre-populated concept reference
#   mappings on the first boot. `MappingsConceptLineProcessor.fill()` clears
#   `concept.getConceptMappings()` for every concept listed in a content
#   package's `concepts.csv` and re-adds only what the CSV's `Same as mappings`
#   column declares -- which, for this distribution's content package, is
#   nothing. 18,882 seed mappings become 724.
#
#   Nothing in the boot reports this. OpenMRS starts cleanly, the login page
#   works, and only the features that resolve a concept by an external code --
#   drug orders, lab orders, medication workflows, the concept search in the
#   order forms, FHIR concept translation -- quietly return nothing. So the
#   damage has to be detected and repaired by a job that runs afterwards and
#   fails the deployment when it cannot make the install whole.
#
# What it does
#   1. ARCHIVE  Ensure openmrs_concept_map_archive holds the seed's mappings.
#               Normally seed.sh already populated it before the backend could
#               boot. If it is empty -- which is the case for any deployment
#               created before this job existed, whose mappings are already gone
#               -- it is rebuilt from the seed dump this image carries, which is
#               the only remaining source of truth.
#   2. REPAIR   Replay any archived mapping that is missing.
#   3. VERIFY   Assert the invariants that make the install usable. Any failure
#               exits non-zero, so `docker compose up` reports a broken
#               deployment instead of leaving it half-working.
#
# Cost
#   A single query and, only when the archive is empty, one import of the seed
#   dump into a scratch schema. Neither happens on a healthy install.
# ---------------------------------------------------------------------------
set -euo pipefail

log() { echo "[db-verify] $*"; }
die() { echo "[db-verify] ERROR: $*" >&2; exit 1; }

DB_HOST="${OMRS_DB_HOST:-db}"
DB_PORT="${OMRS_DB_PORT:-3306}"
DB_NAME="${OMRS_DB_NAME:-openmrs}"
# Only used to identify the application's own statements in information_schema, so
# that "the load has settled" is not confused by this job's own polling.
APP_USER="${OMRS_DB_USER:-openmrs}"
SEED_SQL="${OMRS_DB_SEED_FILE:-/openmrs-seed/seed.sql}"
REPAIR_SQL="${OMRS_DB_REPAIR_SQL:-/usr/local/share/concept-map-repair.sql}"
# Schema the seed dump is imported into when the archive has to be rebuilt.
# Deliberately not a guess: a schema named like the live one would be a
# foot-gun if this script were ever pointed at the wrong server.
SCRATCH_DB="${DB_NAME}_seed_snapshot"

ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD must be set}"

MYSQL=(mariadb --protocol=tcp -h "${DB_HOST}" -P "${DB_PORT}" -u root "-p${ROOT_PASSWORD}")

log "waiting for ${DB_HOST}:${DB_PORT}"
for _ in $(seq 1 120); do
    if "${MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
"${MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1 \
    || die "database at ${DB_HOST}:${DB_PORT} never became available"

# The backend healthcheck that gates this service confirms the WAR is deployed and
# the modules are unpacked. It does NOT confirm the Initializer has finished: it
# runs the CSV loaders long after that, and those are what destroy the mappings.
# Verifying too early would repair the table and then watch the loader delete it
# again, reporting success on a database it had just re-broken.
#
# Two signals, because either alone is weak. The mapping count is what the loader
# moves; an active statement from the application account is what it is doing
# while it does. Requiring both to be quiet for a run of samples is a strong
# indication, not a proof -- the loader deletes roughly nine rows a minute spread
# across the file, so a brief pause is possible. That residual risk is why this is
# a gate and not the fix: correctness rests on the Liquibase changeset in the
# content package, which repairs on every boot regardless of what this job
# observes. A timeout is a failure here, never a pass.
log "waiting for the Initializer to finish loading its content packages"
SETTLE_SAMPLES_REQUIRED=4
SETTLE_INTERVAL=20
TIMEOUT="${OMRS_DB_VERIFY_TIMEOUT_SECONDS:-1800}"
last_maps=""
stable=0
settled=0
elapsed=0
while [ "${elapsed}" -lt "${TIMEOUT}" ]; do
    maps=$("${MYSQL[@]}" -N -B -e "
        SELECT COUNT(*) FROM \`${DB_NAME}\`.concept_reference_map;" 2>/dev/null || echo "")
    active=$("${MYSQL[@]}" -N -B -e "
        SELECT COUNT(*) FROM information_schema.PROCESSLIST
         WHERE DB = '${DB_NAME}' AND COMMAND <> 'Sleep'
           AND USER = '${APP_USER}';" 2>/dev/null || echo "0")

    if [ -n "${maps}" ] && [ "${active}" = "0" ] && [ "${maps}" = "${last_maps}" ]; then
        stable=$((stable + 1))
        [ "${stable}" -ge "${SETTLE_SAMPLES_REQUIRED}" ] && settled=1 && break
    else
        stable=0
    fi
    last_maps="${maps}"
    sleep "${SETTLE_INTERVAL}"
    elapsed=$((elapsed + SETTLE_INTERVAL))
done

if [ "${settled}" -ne 1 ]; then
    die "the Initializer was still working on concept metadata after ${TIMEOUT}s, so
   this install cannot be verified yet. Check docker compose logs backend for a
   stalled content package load. Refusing to report success on a database that may
   still be changing."
fi
log "terminology has stopped changing; proceeding"

# --- 1. ARCHIVE --------------------------------------------------------------
# Counted before anything else, because the rebuild below is only worth doing
# when there is genuinely nothing to repair from.
ARCHIVE_EXISTS=$("${MYSQL[@]}" -N -B -e "
    SELECT COUNT(*) FROM information_schema.TABLES
     WHERE TABLE_SCHEMA='${DB_NAME}'
       AND TABLE_NAME='openmrs_concept_map_archive';" 2>/dev/null || echo 0)
ARCHIVE_ROWS=0
[ "${ARCHIVE_EXISTS}" = "1" ] && ARCHIVE_ROWS=$("${MYSQL[@]}" -N -B -e "
    SELECT COUNT(*) FROM \`${DB_NAME}\`.openmrs_concept_map_archive;" 2>/dev/null || echo 0)

if [ "${ARCHIVE_ROWS}" -eq 0 ]; then
    # Either a fresh install whose seed predates this job, or a legacy install
    # whose mappings were already destroyed. Both are recoverable from the dump,
    # because the dump is the pre-populated seed and therefore the record of
    # what the mappings were.
    [ -s "${SEED_SQL}" ] || die "no seed dump at ${SEED_SQL}, and the mapping
   archive is empty, so the destroyed mappings cannot be recovered. Re-run
   db-init against a clean volume: docker compose down -v && docker compose up -d"
    [ -s "${REPAIR_SQL}" ] || die "repair SQL not found at ${REPAIR_SQL}"

    log "mapping archive is empty; rebuilding it from ${SEED_SQL}"
    log "this imports the seed once; several minutes of inactivity is normal"

    "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`;
                       CREATE DATABASE \`${SCRATCH_DB}\` CHARACTER SET utf8mb4;" \
        || die "could not create the scratch schema ${SCRATCH_DB}"

    RESTORE_RC=0
    "${MYSQL[@]}" "${SCRATCH_DB}" < "${SEED_SQL}" || RESTORE_RC=$?
    [ "${RESTORE_RC}" -eq 0 ] || {
        "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`;" || true
        die "importing the seed dump into ${SCRATCH_DB} failed (rc=${RESTORE_RC})"
    }

    # The seed's `creator` is the daemon user of the seed database. Copying that
    # id across would be wrong, so the archive is built without it and the
    # repair assigns the live database's daemon user.
    "${MYSQL[@]}" "${DB_NAME}" <<SQL || die "could not populate the mapping archive"
CREATE TABLE IF NOT EXISTS openmrs_concept_map_archive (
    uuid                      CHAR(38)  NOT NULL,
    concept_id                INT(11)   NOT NULL,
    concept_reference_term_id INT(11)   NOT NULL,
    concept_map_type_id       INT(11)   NOT NULL,
    date_created              DATETIME  NOT NULL,
    PRIMARY KEY (uuid),
    KEY archive_for_concept (concept_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT IGNORE INTO openmrs_concept_map_archive
    (uuid, concept_id, concept_reference_term_id, concept_map_type_id, date_created)
SELECT m.uuid, m.concept_id, m.concept_reference_term_id, m.concept_map_type_id,
       m.date_created
  FROM \`${SCRATCH_DB}\`.concept_reference_map m;
SQL
    "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`;" || true
    log "mapping archive rebuilt"
else
    log "mapping archive already holds ${ARCHIVE_ROWS} mappings"
fi

# --- 2. REPAIR ---------------------------------------------------------------
[ -s "${REPAIR_SQL}" ] || die "repair SQL not found at ${REPAIR_SQL}"
log "replaying archived concept reference mappings"
"${MYSQL[@]}" "${DB_NAME}" < "${REPAIR_SQL}" \
    || die "repairing the concept reference mappings failed"

# --- 3. VERIFY ---------------------------------------------------------------
# Every assertion below has a failure mode that is invisible from the UI, which
# is the reason this job exists. The thresholds are the ones the seed is built
# to satisfy, not round numbers chosen to pass.
read -r MAPS ARCHIVED MAPTYPE DANGLING CONCEPTS CRM TERMS DRUGS SETS_MISSING SETS_TOTAL <<<"$("${MYSQL[@]}" -N -B "${DB_NAME}" -e "
    SELECT
      (SELECT COUNT(*) FROM concept_reference_map),
      (SELECT COUNT(*) FROM openmrs_concept_map_archive),
      (SELECT COUNT(DISTINCT concept_map_type_id) FROM concept_reference_map),
      (SELECT COUNT(*) FROM concept_reference_map m
         LEFT JOIN concept c ON c.concept_id = m.concept_id
         LEFT JOIN concept_reference_term t
                ON t.concept_reference_term_id = m.concept_reference_term_id
        WHERE c.concept_id IS NULL OR t.concept_reference_term_id IS NULL),
      (SELECT COUNT(*) FROM concept),
      (SELECT COUNT(*) FROM concept_reference_map),
      (SELECT COUNT(*) FROM concept_reference_term),
      (SELECT COUNT(*) FROM drug),
      (SELECT COUNT(*) FROM concept c
        WHERE c.is_set = 0
          AND EXISTS (SELECT 1 FROM concept_set s WHERE s.concept_set = c.concept_id)),
      (SELECT COUNT(*) FROM concept c
        WHERE EXISTS (SELECT 1 FROM concept_set s WHERE s.concept_set = c.concept_id));" \
    2>/dev/null || echo "0 0 0 0 0 0 0 0 0 0")"

# The single check this whole job is about. A shortfall means mappings are still
# missing, so features that resolve concepts by external code will return nothing.
[ "${MAPS}" -ge "${ARCHIVED}" ] || die "concept reference mappings are still short:
   ${MAPS} present, ${ARCHIVED} archived. The repair did not take effect."

# Maps that point at a concept or term that no longer exists are worse than
# absent: the modules that read them follow the dangling reference.
[ "${DANGLING}" -eq 0 ] || die "${DANGLING} concept reference mappings point at a
   deleted concept or reference term. Restore the metadata or remove the mapping."

# The seed is built with CIEL across many map types. A single surviving map type
# means the mappings were replaced rather than lost, which is a different defect
# and should not be reported as this one.
[ "${MAPTYPE}" -ge 3 ] || die "only ${MAPTYPE} concept map type(s) present.
   The pre-populated seed maps CIEL concepts across many map types, so this
   install has been rewritten rather than merely damaged."

# The rest are the supporting metadata order entry resolves through concept sets.
# Each maps to a concrete, already-reported failure.
[ "${CONCEPTS}" -gt 3000 ] || die "only ${CONCEPTS} concepts; the seed guarantees more than 3000"
[ "${CRM}" -gt 3000 ]      || die "only ${CRM} concepts carry a reference mapping"
[ "${TERMS}" -gt 3000 ]    || die "only ${TERMS} reference terms; CIEL terminology is missing"
[ "${DRUGS}" -gt 0 ]       || die "no drugs; medication and drug orders cannot be created"
[ "${SETS_MISSING}" -eq 0 ] || die "${SETS_MISSING} concepts that have set members are
   not flagged is_set. OrderService resolves drug routes, dosing and dispensing
   units with getSetMembers(), so every drug order fails validation with
   DrugOrder.error.routeNotAmongAllowedConcepts and the Orders widget stays
   empty. (${SETS_MISSING} of ${SETS_TOTAL})"

log "terminology verified"
{
    echo "### Terminology integrity"
    echo
    echo "| metric | value |"
    echo "|---|---|"
    echo "| concept reference mappings | ${MAPS} |"
    echo "| archived mappings | ${ARCHIVED} |"
    echo "| concept map types in use | ${MAPTYPE} |"
    echo "| dangling mappings | ${DANGLING} |"
    echo "| concepts | ${CONCEPTS} |"
    echo "| concepts with a reference mapping | ${CRM} |"
    echo "| reference terms | ${TERMS} |"
    echo "| drugs | ${DRUGS} |"
    echo "| set concepts missing is_set | ${SETS_MISSING} |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

log "complete"
