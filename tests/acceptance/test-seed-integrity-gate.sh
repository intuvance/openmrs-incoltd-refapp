#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Regression tests for the integrity gate in deployment/db/seed.sh.
#
# The gate is the thing that decides whether a running install still holds the
# terminology the seed installed. It runs on every `docker compose up` against a
# database it did not create, so "no output means intact" has to be true for a
# healthy install and false for each way the install can be damaged -- otherwise
# it either restores unnecessarily on every boot, or lets a broken install
# through.
#
# These tests exercise the gate's SQL directly, against a throwaway MariaDB with a
# miniature OpenMRS schema. They are cheap and need no OpenMRS image, no seed dump
# and no backend, so they can run before the expensive end-to-end boot test.
#
# Usage:
#   tests/acceptance/test-seed-integrity-gate.sh [image]
#
# Defaults to mariadb:10.11.7, the same image the stack runs.
#
# Exit codes
#   0  every scenario behaved as specified
#   1  a scenario regressed
#   2  the harness itself could not run (bad image, no docker, timeout)
# ---------------------------------------------------------------------------
set -uo pipefail

MARIADB_IMAGE="${1:-mariadb:10.11.7}"
CONTAINER="seed-gate-test-$$"
DB="openmrs"
ROOT_PW="gate-test-password"

PASSED=0
FAILED=0

cleanup() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail_harness() { echo "HARNESS ERROR: $*" >&2; exit 2; }
sql() { docker exec -i "${CONTAINER}" mariadb -uroot "-p${ROOT_PW}" "$@"; }

docker version >/dev/null 2>&1 || fail_harness "docker is not available"

echo "starting ${MARIADB_IMAGE} ..."
docker run -d --name "${CONTAINER}" \
    -e "MARIADB_ROOT_PASSWORD=${ROOT_PW}" \
    -e "MARIADB_DATABASE=${DB}" \
    "${MARIADB_IMAGE}" >/dev/null || fail_harness "could not start ${MARIADB_IMAGE}"

for _ in $(seq 1 60); do
    if docker exec "${CONTAINER}" mariadb -uroot "-p${ROOT_PW}" -e "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
docker exec "${CONTAINER}" mariadb -uroot "-p${ROOT_PW}" -e "SELECT 1" >/dev/null 2>&1 \
    || fail_harness "MariaDB never became available"

# A miniature of the tables the gate reads, with the columns it depends on. The
# gate is pure SQL over these, so this is the whole surface it has.
sql "${DB}" >/dev/null <<'SQL' || fail_harness "could not create the test schema"
CREATE TABLE concept (
    concept_id INT AUTO_INCREMENT PRIMARY KEY,
    uuid CHAR(38) NOT NULL,
    is_set TINYINT DEFAULT 0
);
CREATE TABLE concept_map_type (
    concept_map_type_id INT AUTO_INCREMENT PRIMARY KEY,
    uuid CHAR(38)
);
CREATE TABLE concept_reference_map (
    concept_map_id INT AUTO_INCREMENT PRIMARY KEY,
    concept_id INT,
    uuid CHAR(38)
);
CREATE TABLE concept_set (
    concept_set_id INT AUTO_INCREMENT PRIMARY KEY,
    concept_set INT,
    concept_id INT
);
CREATE TABLE openmrs_seed_concept_manifest (uuid CHAR(38) NOT NULL, PRIMARY KEY (uuid));
CREATE TABLE openmrs_concept_map_archive (
    uuid CHAR(38) NOT NULL PRIMARY KEY,
    concept_id INT
);
SQL

# The gate's SQL, kept byte-identical to the heredoc in seed.sh. Extracted from
# seed.sh itself so the two cannot drift apart. The extractor walks from the
# integrity_report() definition to its heredoc terminator, skipping the shell
# command line that opens the heredoc.
GATE_SQL="$(awk '
    /^integrity_report\(\) \{$/          { in_fn = 1; next }
    in_fn && /<<'"'"'SQL'"'"'$/            { in_sql = 1; next }
    in_fn && in_sql && /^SQL$/            { exit }
    in_fn && in_sql                      { print }
' "$(dirname "$0")/../../deployment/db/seed.sh")"
[ -n "${GATE_SQL}" ] || fail_harness "could not extract integrity_report() from seed.sh"

report() { sql -N -B "${DB}" <<<"${GATE_SQL}"; }

reset() {
    sql "${DB}" >/dev/null <<'SQL'
TRUNCATE concept;
TRUNCATE concept_map_type;
TRUNCATE concept_reference_map;
TRUNCATE concept_set;
TRUNCATE openmrs_seed_concept_manifest;
TRUNCATE openmrs_concept_map_archive;
SQL
}

# A healthy seeded install: three concepts, one of which is a set, three concept
# map types, four mappings, and a manifest plus archive that match the live rows.
# concept_set(concept_set=3) means concept 3 is a set holding concept 1.
healthy() {
    sql "${DB}" >/dev/null <<'SQL'
INSERT INTO concept (uuid,is_set) VALUES ('u-1',0),('u-2',0),('u-3',1);
INSERT INTO concept_map_type (uuid) VALUES ('m1'),('m2'),('m3');
INSERT INTO concept_reference_map (concept_id,uuid) VALUES (1,'r1'),(2,'r2'),(3,'r3'),(1,'r4');
INSERT INTO concept_set (concept_set,concept_id) VALUES (3,1);
INSERT INTO openmrs_seed_concept_manifest (uuid) VALUES ('u-1'),('u-2'),('u-3');
INSERT INTO openmrs_concept_map_archive (uuid,concept_id) VALUES ('r1',1),('r2',2),('r3',3),('r4',1);
SQL
}

check() {
    local name="$1" want="$2" got
    got="$(report)"
    if [ "${got}" = "${want}" ]; then
        echo "PASS  ${name}"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL  ${name}"
        echo "        expected: [${want}]"
        echo "        actual:   [${got}]"
        FAILED=$((FAILED + 1))
    fi
}

echo
echo "running gate scenarios"

# --- the gate must stay silent on a healthy install -------------------------
reset; healthy
check "healthy install reports no drift" ""

reset; healthy
sql "${DB}" -e "INSERT INTO concept (uuid,is_set) VALUES ('admin-added',0);"
check "concepts an administrator added are not drift" ""

# The repository documents this: a package can no longer blank terminology by
# omitting a column, so an install whose concepts grew legitimately stays put.
reset; healthy
sql "${DB}" -e "INSERT INTO concept_reference_map (concept_id,uuid) VALUES (2,'r-admin');"
check "mappings beyond the archive are not drift" ""

# An install whose mappings were already repaired has fewer archived than live.
reset; healthy
sql "${DB}" -e "DELETE FROM openmrs_concept_map_archive WHERE uuid='r3';"
check "already-repaired install reports no drift" ""

# --- the exact regression this whole change exists to prevent ---------------
# Upstream Initializer 2.12.0 cleared concept.getConceptMappings() for every
# concept it loaded and re-added only what the CSV column declared. This distro's
# concepts.csv declares none, so the archive is all that is left.
reset; healthy
sql "${DB}" -e "DELETE FROM concept_reference_map;"
check "mappings wiped by the upstream Initializer are detected" \
  "concept reference mappings lost: archive holds 4 but only 0 remain -- the Initializer destroyed them"

reset; healthy
sql "${DB}" -e "DELETE FROM concept_reference_map WHERE uuid='r1';"
check "partial mapping loss is detected" \
  "concept reference mappings lost: archive holds 4 but only 3 remain -- the Initializer destroyed them"

# --- the other ways a seeded install can be wrong ---------------------------
# Deleting a seeded concept legitimately orphans its mappings, so both checks fire.
reset; healthy
sql "${DB}" -e "DELETE FROM concept WHERE uuid='u-2';"
check "a deleted seeded concept is detected" \
  "concepts missing from the seed: 1
dangling concept reference mappings: 1"

reset; healthy
sql "${DB}" -e "INSERT INTO concept_reference_map (concept_id,uuid) VALUES (999,'rX');"
check "a mapping pointing at no concept is detected" \
  "dangling concept reference mappings: 1"

# Fewer than three map types means the terminology was replaced rather than
# thinned, which is a different failure and must not read as a pass.
reset; healthy
sql "${DB}" -e "DELETE FROM concept_map_type WHERE uuid='m2';"
check "thinned concept map types are detected" \
  "concept map types surviving: 2 -- fewer than three means the terminology was replaced, not merely thinned"

# concept 3 is the set, so it is its is_set flag that matters. Clearing the flag
# on concept 1, which is only a member, is not a defect.
reset; healthy
sql "${DB}" -e "UPDATE concept SET is_set=0 WHERE concept_id=3;"
check "is_set out of step with concept_set rows is detected" \
  "concept_set rows disagree with concept.is_set: 1"

reset; healthy
sql "${DB}" -e "UPDATE concept SET is_set=0 WHERE concept_id=1;"
check "clearing is_set on a set member is not drift" ""

echo
echo "---- ${PASSED} passed, ${FAILED} failed ----"
[ "${FAILED}" -eq 0 ]
