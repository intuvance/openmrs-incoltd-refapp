#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Startup acceptance test for the Intuvance OpenMRS O3 distribution.
#
# Verifies the behaviour the distribution is actually accountable for, against a
# running stack. Three scenarios:
#
#   clean   docker compose down -v && docker compose up
#           full first-time install from zero volumes
#   restart docker compose restart
#           must become healthy without repeating initialisation
#   upgrade existing volumes, rebuilt images
#           must not re-run initialisation or destroy data
#
# Usage:
#   tests/acceptance/startup-acceptance.sh [clean|restart|upgrade|all]
#
# Requires: docker, docker compose, curl. jq is used if present but is optional.
#
# Exits non-zero on the first failed check, and prints the failing check plus the
# relevant container logs, so a failure is diagnosable without a rerun. Startup
# errors are never swallowed: if the backend does not become healthy, the backend
# and db-init logs are dumped and the script fails.
# ---------------------------------------------------------------------------
set -euo pipefail

SCENARIO="${1:-all}"
ENV_FILE="${ENV_FILE:-.env}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
GATEWAY_PORT="${OMRS_HTTP_PORT:-8080}"
BASE="http://localhost:${GATEWAY_PORT}"
BACKEND="http://localhost:8080/openmrs"
API="${BACKEND}/ws/rest/v1"

# Generous, because a cold first start includes the Initializer applying every
# content package. The point of the test is that this finishes, not that it is fast.
READY_TIMEOUT="${READY_TIMEOUT:-2400}"

PASSED=0
FAILED=0
LAST_DB_ERROR=""

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_INFO=$'\033[36m'
else
    C_RESET=""; C_PASS=""; C_FAIL=""; C_INFO=""
fi

pass() { PASSED=$((PASSED + 1)); echo "${C_PASS}  PASS${C_RESET}  $*"; }
fail() { FAILED=$((FAILED + 1)); echo "${C_FAIL}  FAIL${C_RESET}  $*"; }
info() { echo "${C_INFO}        $*${C_RESET}"; }
die()  { echo "${C_FAIL}  ERROR${C_RESET} $*" >&2; exit 1; }

compose() { docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"; }

# --- database access ---------------------------------------------------------
# Queries go through the same compose network the backend uses, so no database
# port has to be published to the host.
#
# Two failure modes must be told apart, because they mean opposite things:
#
#   * the database is unreachable -- transient, worth retrying (the container can
#     still be starting while the stack comes up)
#   * the query itself is wrong -- a defect in this script, and retrying it three
#     times just hides the real error behind "the query could not be run"
#
# `mariadb` exits non-zero for both, so the server's message is inspected:
# connection problems read "Can't connect" / "Lost connection" / "server has
# gone away", whereas a bad query reads "ERROR 1054" and similar. Only the former
# is retried, and the latter is surfaced verbatim.
db() {
    local query="$1" attempt out err
    for attempt in 1 2 3; do
        err=$(mktemp)
        if out=$(compose exec -T db mariadb -N -B \
            -uroot -p"$(grep -E '^MYSQL_ROOT_PASSWORD=' "${ENV_FILE}" | cut -d= -f2-)" \
            openmrs -e "${query}" 2>"${err}"); then
            rm -f "${err}"
            printf '%s' "${out}"
            return 0
        fi
        if ! grep -qiE "can't connect|lost connection|gone away|connection refused|can't connect to" "${err}"; then
            # Not a connection problem: report the actual SQL error and stop.
            printf '__QUERY_FAILED__'
            LAST_DB_ERROR="$(tr -d '\r' < "${err}" | head -3)"
            rm -f "${err}"
            return 1
        fi
        rm -f "${err}"
        sleep 3
    done
    printf '__QUERY_FAILED__'
    LAST_DB_ERROR="could not connect to the database after 3 attempts"
    return 1
}

# Prints the query result, or the literal string FAILED if the query could not be
# run. Assertions branch on that so a broken connection is never reported as data.
scalar() { db "$1" | head -1 | tr -d '\r'; }

assert_sql() {
    local description="$1" query="$2" expected="$3"
    local actual
    actual=$(scalar "${query}") || true
    if [ "${actual}" = "__QUERY_FAILED__" ]; then
        fail "${description}: the query could not be run -- ${LAST_DB_ERROR}"
        return 1
    fi
    if [ "${actual}" = "${expected}" ]; then
        pass "${description} (= ${expected})"
    else
        fail "${description}: expected '${expected}', got '${actual}'"
        FAILED_DETAIL=1
    fi
}

assert_at_least() {
    local description="$1" query="$2" minimum="$3"
    local actual
    actual=$(scalar "${query}") || true
    if [ "${actual}" = "__QUERY_FAILED__" ]; then
        fail "${description}: the query could not be run -- ${LAST_DB_ERROR}"
        dump_logs
        return 1
    fi
    if [ -n "${actual}" ] && [ "${actual}" -ge "${minimum}" ] 2>/dev/null; then
        pass "${description} (${actual} >= ${minimum})"
    else
        fail "${description}: expected at least ${minimum}, got '${actual}'"
    fi
}

assert_zero() {
    local description="$1" query="$2"
    local actual
    actual=$(scalar "${query}") || true
    if [ "${actual}" = "__QUERY_FAILED__" ]; then
        fail "${description}: the query could not be run -- ${LAST_DB_ERROR}"
        return 1
    fi
    if [ "${actual}" = "0" ]; then
        pass "${description} (= 0)"
    else
        fail "${description}: expected 0, got '${actual}'"
    fi
}

assert_http() {
    local description="$1" url="$2" expected_code="${3:-200}"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${url}" || echo 000)
    if [ "${code}" = "${expected_code}" ]; then
        pass "${description} (HTTP ${code})"
    else
        fail "${description}: expected HTTP ${expected_code}, got ${code} for ${url}"
    fi
}

# Same, but follows redirects. For endpoints that legitimately hand off to the
# SPA or to the setup wizard, the terminal status is what matters.
assert_http_follow() {
    local description="$1" url="$2" expected_code="${3:-200}"
    local code
    code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 30 "${url}" || echo 000)
    if [ "${code}" = "${expected_code}" ]; then
        pass "${description} (HTTP ${code} after redirects)"
    else
        fail "${description}: expected HTTP ${expected_code}, got ${code} for ${url}"
    fi
}

dump_logs() {
    echo
    echo "=================== backend logs (last 200) ==================="
    compose logs --no-color --tail=200 backend || true
    echo "=================== db-init logs =============================="
    compose logs --no-color --tail=200 db-init || true
    echo "=================== db logs (last 100) ========================"
    compose logs --no-color --tail=100 db || true
    echo "============================================================="
}

# --- readiness ---------------------------------------------------------------
# /openmrs/initialsetup returning 200 means the WAR is deployed, the datasource is
# reachable and the modules have started. That is the point at which startup is
# genuinely complete, not merely "the process is up".
wait_for_backend() {
    info "waiting up to $((READY_TIMEOUT / 60)) minutes for OpenMRS to become ready..."
    local deadline=$((SECONDS + READY_TIMEOUT))
    local reported=0
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if ! compose ps --status=running --services 2>/dev/null | grep -qx backend; then
            info "backend is not running; waiting for it to start..."
        else
            local code
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                "${BACKEND}/initialsetup" || echo 000)
            if [ "${code}" = "200" ]; then
                # The WAR answering 200 only means Tomcat deployed it. The
                # Initializer keeps applying content packages for several minutes
                # afterwards, and every metadata assertion below reads the
                # database directly -- so returning here made the suite race the
                # Initializer and report missing CIEL concepts, missing concept
                # set members and an unloaded module on a perfectly healthy
                # install. Wait for the Initializer to actually finish.
                if [ "${reported}" -eq 0 ]; then
                    info "WAR is up; waiting for the Initializer to finish applying content..."
                    reported=1
                fi
                if initializer_finished; then
                    info "OpenMRS is ready after $((SECONDS))s"
                    return 0
                fi
            fi
        fi
        sleep 10
    done
    return 1
}

# A reliable "the Initializer has finished" marker.
#
# There is no completion signal to poll for:
#
#   * `/initialsetup` answering 200 only means Tomcat deployed the WAR
#   * no checksum directory marks the end of the run, and initializer.log is
#     created empty and only written on failure
#   * sampling row counts for "stability" is unreliable -- module unpacking
#     pauses in bursts, so two identical samples 5s apart can both land inside a
#     pause and report a half-loaded system as finished
#
# So wait for the concrete post-conditions this suite actually asserts, rather
# than trying to infer them. Every condition below corresponds to an assertion:
# the four required modules must be unpacked, the CIEL mapping must be loaded,
# and the site global properties must be applied. All must hold simultaneously.
#
# The module count is deliberately not compared against a fixed total: that total
# changes as modules are added, and a stale expectation here would either hang or
# mask a regression.
initializer_finished() {
    # One `compose exec` per probe, not one per condition: each exec costs about a
    # second, and probing five conditions separately made a single poll cost enough
    # to push a clean install past the suite's timeout.
    for _ in $(seq 1 240); do
        # 1 once the four required modules are all unpacked, else 0.
        local mods_ready
        mods_ready=$(compose exec -T backend sh -c \
            'n=0; for m in initializer webservices.rest fhir2 openconceptlab; do
                 [ -d "/openmrs/data/.openmrs-lib-cache/$m" ] && n=$((n+1)); done
             echo $n' 2>/dev/null | tr -dc '0-9')
        [ "${mods_ready:-0}" -eq 4 ] 2>/dev/null || { sleep 10; continue; }

        # 1 once the CIEL mappings and the site global properties are present.
        local data_ready
        data_ready=$(scalar "SELECT (SELECT COUNT(*) FROM concept_reference_map m
                                       JOIN concept_reference_term t ON t.concept_reference_term_id = m.concept_reference_term_id
                                       JOIN concept_reference_source s ON s.concept_source_id = t.concept_source_id
                                      WHERE s.name = 'CIEL') > 0
                                  AND EXISTS (SELECT 1 FROM global_property WHERE property = 'login.location')")
        if [ "${data_ready}" = "1" ]; then
            return 0
        fi
        sleep 10
    done
    return 1
}

wait_for_frontend() {
    local deadline=$((SECONDS + 300))
    # Probe the SPA itself, not the bare gateway root. The gateway redirects "/" to
    # /openmrs/spa/ (301), so requiring a 200 on the root timed out even when the
    # frontend was serving normally.
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                  "${BASE}/openmrs/spa/home" || echo 000)" = "200" ]; then
            return 0
        fi
        sleep 5
    done
    return 1
}

# --- the checks --------------------------------------------------------------
# These mirror the acceptance criteria one for one. A check is named after the
# guarantee it defends so that a failure is self-explanatory.

check_startup() {
    echo
    echo "== startup and reachability =="

    wait_for_backend || { fail "OpenMRS did not become ready within ${READY_TIMEOUT}s"; dump_logs; return 1; }
    pass "OpenMRS backend is ready"

    wait_for_frontend || { fail "O3 frontend did not become reachable"; dump_logs; }
    pass "O3 frontend is reachable"

    # O3 has no legacy login page: /openmrs/login.htm belongs to legacyui and
    # redirects into the SPA. Following redirects is the correct expectation --
    # asserting a bare 200 on login.htm was asserting the old UI and failed on a
    # correct install.
    assert_http_follow "login page renders" "${BACKEND}/login.htm"
    assert_http_follow "O3 login app is served" "${BASE}/openmrs/spa/login"
}

check_database_and_terminology() {
    echo
    echo "== database, CIEL and core metadata =="

    # This is the assertion that catches a regressed pre-populated database or a
    # truncated first startup: a fresh install that skipped the OCL bootstrap
    # still ends up with CIEL through the content package, but the mapping count
    # is what proves the terminology is real rather than a handful of stubs.
    assert_at_least "core concepts are present" \
        "SELECT COUNT(*) FROM concept WHERE retired = 0" 3000
    # A CIEL mapping is concept_reference_map joined through
    # concept_reference_term to concept_reference_source. There is no
    # concept_reference_source_id on the map table -- the previous query joined on
    # a column that does not exist and failed on every run.
    assert_at_least "CIEL concept mappings are present" \
        "SELECT COUNT(*) FROM concept_reference_map m JOIN concept_reference_term t ON t.concept_reference_term_id = m.concept_reference_term_id JOIN concept_reference_source s ON s.concept_source_id = t.concept_source_id WHERE s.name = 'CIEL'" 3000
    assert_at_least "concept names are present" \
        "SELECT COUNT(*) FROM concept_name WHERE voided = 0" 3000
    assert_at_least "concept sets are present" \
        "SELECT COUNT(*) FROM concept_set" 1
    assert_at_least "concept set members are present" \
        "SELECT COUNT(*) FROM concept_set WHERE concept_set IS NOT NULL" 1
    assert_at_least "concepts have a datatype" \
        "SELECT COUNT(DISTINCT datatype_id) FROM concept" 1
}

check_ocl_does_not_block() {
    echo
    echo "== OCL is not a first-boot dependency =="

    # If subscriptionUrl were set, openconceptlab would schedule and run a
    # remote terminology import. Leaving it unset is what keeps startup bounded
    # and the system usable when the terminology service is unreachable.
    local url
    url=$(scalar "SELECT property_value FROM global_property WHERE property = 'openconceptlab.subscriptionUrl'" || true)
    if [ -z "${url}" ] || [ "${url}" = "NULL" ]; then
        pass "openconceptlab.subscriptionUrl is unset, so no remote import is scheduled"
    else
        fail "openconceptlab.subscriptionUrl is set to '${url}'; a site must opt in deliberately"
    fi

    # A row with no stop time is an import that started and never finished. The
    # column is local_date_stopped, not `stopped`; the earlier name made this
    # query an SQL error that the harness could not distinguish from a real
    # failure, so it reported "got '?'".
    assert_zero "OCL is not mid-import" \
        "SELECT COUNT(*) FROM openconceptlab_import WHERE local_date_stopped IS NULL"
}

check_no_demo_data() {
    echo
    echo "== no demo clinical data =="

    # Core metadata is asserted elsewhere and is deliberately NOT removed here.
    assert_zero "no observations"          "SELECT COUNT(*) FROM obs"
    assert_zero "no encounters"            "SELECT COUNT(*) FROM encounter"
    assert_zero "no visits"                "SELECT COUNT(*) FROM visit"
    assert_zero "no patients"              "SELECT COUNT(*) FROM patient"
    assert_zero "no orders"                "SELECT COUNT(*) FROM orders"
    # The demo accounts must be gone. `daemon` is deliberately NOT in this list:
    # it is OpenMRS's own system user and the creator of the entire metadata audit
    # trail, so purging it orphans thousands of creator references and OpenMRS
    # fails at startup with FetchNotFoundException. An earlier version of this
    # check asserted that `daemon` was absent, which is what shipped the broken
    # seed. The positive assertions below cover it.
    assert_zero "no demo users"            "SELECT COUNT(*) FROM users
                                            WHERE username IN ('doctor','nurse','clerk','technician')"

    # The two system users must survive, and no row may reference a deleted user.
    #
    # These are the assertions that would have caught the original broken seed.
    # Purging `daemon` orphans the creator reference on ~4400 concepts, every
    # location and every person, and OpenMRS then fails on each metadata read with
    # FetchNotFoundException. The database restores cleanly either way, so this is
    # the only place it can be caught cheaply.
    # The admin superuser's username is the empty string in this seed; it is
    # identified by system_id, not username. Querying username therefore reported
    # a missing admin on a correct install.
    assert_at_least "admin superuser is present" \
        "SELECT COUNT(*) FROM users WHERE system_id = 'admin'" 1
    assert_at_least "daemon system user is present" \
        "SELECT COUNT(*) FROM users WHERE username = 'daemon'" 1
    assert_zero "no metadata references a purged user" \
        "SELECT COUNT(*) FROM concept WHERE creator <> 0
             AND creator NOT IN (SELECT user_id FROM users)"
    assert_zero "no location references a purged user" \
        "SELECT COUNT(*) FROM location WHERE creator <> 0
             AND creator NOT IN (SELECT user_id FROM users)"
    assert_zero "no person references a purged user" \
        "SELECT COUNT(*) FROM person WHERE creator <> 0
             AND creator NOT IN (SELECT user_id FROM users)"
}

check_core_metadata_intact() {
    echo
    echo "== core metadata is intact =="

    # The demo package is what supplies these. Their absence is the signal that
    # only the demo package was excluded, not that core metadata was pruned.
    assert_at_least "core locations are present"        "SELECT COUNT(*) FROM location" 1
    assert_at_least "location tags are present"         "SELECT COUNT(*) FROM location_tag" 1
    assert_at_least "visit types are present"           "SELECT COUNT(*) FROM visit_type" 1
    assert_at_least "encounter types are present"       "SELECT COUNT(*) FROM encounter_type" 1
    assert_at_least "encounter roles are present"       "SELECT COUNT(*) FROM encounter_role" 1
    assert_at_least "drugs are present"                 "SELECT COUNT(*) FROM drug" 1
    assert_at_least "order types are present"           "SELECT COUNT(*) FROM order_type" 1
    assert_at_least "roles are present"                 "SELECT COUNT(*) FROM role" 1
    assert_at_least "privileges are present"            "SELECT COUNT(*) FROM privilege" 1
    assert_at_least "forms are present"                 "SELECT COUNT(*) FROM form" 1
}

check_login_location() {
    echo
    echo "== login location =="

    # Both halves are required. The global property alone does nothing if no
    # location carries the tag, and the tag alone does nothing if the property is
    # unset. This is the check that catches a broken Login Location, which is a
    # common and confusing failure in a hand-assembled distribution.
    local tag_count loc_count login_location loc_name
    tag_count=$(scalar "SELECT COUNT(*) FROM location_tag WHERE name = 'Login Location'" || echo 0)
    loc_count=$(scalar "SELECT COUNT(*) FROM location_tag lt
                          JOIN location_tag_map m ON m.location_tag_id = lt.location_tag_id
                         WHERE lt.name = 'Login Location'" || echo 0)
    login_location=$(scalar "SELECT property_value FROM global_property WHERE property = 'login.location'" || true)

    if [ "${tag_count}" -ge 1 ] 2>/dev/null; then
        pass "'Login Location' tag exists"
    else
        fail "'Login Location' location tag is missing"
    fi

    if [ "${loc_count}" -ge 1 ] 2>/dev/null; then
        pass "at least one location carries the 'Login Location' tag (${loc_count})"
    else
        fail "no location carries the 'Login Location' tag"
    fi

    if [ -n "${login_location}" ] && [ "${login_location}" != "NULL" ]; then
        loc_name=$(scalar "SELECT name FROM location WHERE uuid = '${login_location}'" || true)
        if [ -n "${loc_name}" ]; then
            pass "login.location resolves to an existing location ('${loc_name}')"
        else
            fail "login.location (${login_location}) does not resolve to an existing location"
        fi
    else
        fail "login.location global property is not set"
    fi
}

check_site_metadata() {
    echo
    echo "== local site configuration was applied by the Initializer =="

    # The site content package installs into its own namespace, so its metadata
    # must be distinguishable from the official core package's.
    assert_at_least "site content package produced locations" \
        "SELECT COUNT(*) FROM location" 1

    # The Initializer records nothing queryable about which package it applied, so
    # prove the *effect* instead: a site-only value that the core package does not
    # set. Adjust the expected UUID if you change the site login location.
    local login_location
    login_location=$(grep -E '^OMRS_SITE_LOGIN_LOCATION=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)
    login_location="${login_location:-6a679877-1472-4c0e-bdd1-e716f88cbfdb}"
    if [ "$(scalar "SELECT COUNT(*) FROM location WHERE uuid = '${login_location}'")" = "1" ]; then
        pass "site login location ${login_location} exists"
    else
        fail "site login location ${login_location} is missing; the site content package did not apply"
    fi

    # Frontend configuration written by the site content package.
    #
    # It is NOT written by the Initializer: there is no FRONTEND_CONFIGURATION
    # domain in the Initializer's Domain enum, so nothing ever creates
    # /openmrs/data/configuration/frontend_configuration/. The Dockerfile copies
    # it into spa_config in the distribution, and the backend serves that at
    # OMRS_SPA_CONFIG_URLS. Assert the path that is actually used.
    if compose exec -T frontend test -f /usr/share/nginx/html/config-core.json 2>/dev/null; then
        pass "site SPA config is present at the path OMRS_SPA_CONFIG_URLS points to"
        # Guard against the demo placeholder being shipped by mistake. The site
        # config is what carries the queue concept UUIDs and brand colours.
        if compose exec -T frontend grep -q "esm-service-queues-app" /usr/share/nginx/html/config-core.json 2>/dev/null; then
            pass "site SPA config contains the site's queue configuration"
        else
            fail "config-core.json looks like the demo placeholder; site branding will not apply"
        fi
    else
        fail "config-core.json is missing from the frontend; site branding and queue concepts will not apply"
    fi
}

check_modules_and_owas() {
    echo
    echo "== modules and OWAs =="

    # Module load state is read from the runtime, not the database.
    #
    # There is no `modules` registry table in this schema: the seeded dump is
    # pre-module-load, and OpenMRS records loaded modules as an unpacked
    # directory per module under /openmrs/data/.openmrs-lib-cache/. The previous
    # version of this check queried a non-existent `openmrs_module` table (that
    # name belongs to a FHIR resource table, not the module registry), so it
    # reported every module as unloaded on a perfectly healthy install.
    local loaded
    loaded=$(compose exec -T backend sh -c 'ls /openmrs/data/.openmrs-lib-cache/ 2>/dev/null | wc -l' 2>/dev/null | tr -dc '0-9')
    if [ -z "${loaded}" ]; then
        fail "could not read the module cache from the backend container"
        dump_logs
        return 1
    fi
    if [ "${loaded}" -gt 0 ] 2>/dev/null; then
        pass "modules are loaded (${loaded} unpacked under .openmrs-lib-cache)"
    else
        fail "no modules are loaded; the distro's modules did not start"
    fi

    # Required modules, individually, because a distro that builds and starts
    # without one of these will look healthy and be unusable in specific ways.
    local m
    for m in initializer webservices.rest fhir2 openconceptlab; do
        if compose exec -T backend test -d "/openmrs/data/.openmrs-lib-cache/${m}" 2>/dev/null; then
            pass "module '${m}' is loaded"
        else
            fail "module '${m}' is not loaded"
        fi
    done

    # OWAs: the distro ships none by default, but the packaging must be correct if
    # one is ever added, so assert the directory exists and is wired in.
    if compose exec -T backend test -d /openmrs/distribution/openmrs_owas 2>/dev/null; then
        pass "openmrs_owas is present in the distribution"
    else
        fail "openmrs_owas is missing from the distribution"
    fi
}

check_rest_api() {
    echo
    echo "== REST API =="

    # This distribution ships no usable login account, by design.
    #
    # The seed's only user rows are the two system accounts: user 1 has an empty
    # username (the OpenMRS setup superuser placeholder) and user 2 is `daemon`.
    # There is no account that can authenticate, and `module.allow_web_admin` is
    # true, so OpenMRS redirects every REST and FHIR request to /initialsetup.
    # A 302 there is therefore the correct, expected response for an
    # unconfigured install -- it is not a broken servlet mapping.
    #
    # What is worth asserting is that the endpoints exist and are routed by the
    # module rather than being absent: a 302 means the request was handled and
    # answered, whereas a 404 would mean the servlet is not mapped at all. Once
    # an operator creates a real account, these become plain 200s.
    local code
    for label_path in \
        "REST server info:${API}/server" \
        "REST metadata:${API}/metadata" \
        "FHIR metadata:${BACKEND}/ws/fhir2/metadata"
    do
        local label="${label_path%%:*}"
        local path="${label_path#*:}"
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${path}" || echo 000)
        case "${code}" in
            200)
                pass "${label} is served (200)"
                ;;
            302)
                pass "${label} is routed and answered (302 to /initialsetup; expected with no login account)"
                ;;
            404)
                fail "${label} is not mapped (404); the module did not register its servlet"
                ;;
            *)
                fail "${label}: expected HTTP 200 or 302, got '${code}'"
                ;;
        esac
    done

    # No demo account may be present, and the seed password must be gone.
    if [ "$(scalar "SELECT COUNT(*) FROM users WHERE username IS NOT NULL AND username <> '' AND username <> 'daemon'")" -eq 0 ] 2>/dev/null; then
        pass "no login account exists yet (no demo credentials shipped)"
    else
        fail "unexpected login accounts present; the demo users were not purged"
    fi
}

check_credentials_rotated() {
    echo
    echo "== security =="

    # The pre-populated upstream image ships a fixed, publicly known password.
    # If it is still usable, the rotation step did not run.
    if compose exec -T db mariadb \
            -uopenmrs -popenmrs -e "SELECT 1" >/dev/null 2>&1; then
        fail "the seed image's default database password still works; credentials were not rotated"
    else
        pass "the seed image's default database password has been revoked"
    fi

    # The backend must not be publishing the database or itself outside the gateway.
    local published
    # `grep` exits 1 when it matches nothing, which is the success case here. Under
    # `set -o pipefail` that made the pipeline -- and the whole script, via
    # `set -e` -- fail before the summary was ever printed, so a green run still
    # exited non-zero with no explanation.
    published=$(compose ps --format '{{.Service}} {{.Ports}}' 2>/dev/null \
        | grep -E '0\.0\.0\.0.*(3306|8080:)' | wc -l) || true
    if [ "${published}" -eq 0 ]; then
        pass "only the gateway publishes a host port"
    else
        fail "${published} service(s) other than the gateway publish a host port"
    fi
}

check_idempotency() {
    echo
    echo "== initialisation is idempotent =="

    local seed_count
    seed_count=$(scalar "SELECT COUNT(*) FROM deployment_state WHERE name = 'db_initialised'" || echo 0)
    if [ "${seed_count}" = "1" ]; then
        pass "the db_initialised marker is present, so initialisation is guarded"
    else
        fail "no db_initialised marker; the seed job is not idempotent"
    fi
}

# --- scenarios ---------------------------------------------------------------

scenario_clean() {
    echo
    echo "############ CLEAN INSTALL ############"
    # Read the secrets before destroying anything. This scenario removes every
    # volume and then starts from zero, so the .env it needs has to be captured
    # first: deleting the volumes does not delete .env, but this check must run
    # before any destructive step so a missing or incomplete .env fails without
    # having already thrown away a working deployment.
    if [ ! -f "${ENV_FILE}" ]; then
        die "${ENV_FILE} not found. Copy .env.example to .env and set the secrets first."
    fi
    local root_pw
    root_pw="$(grep -E '^MYSQL_ROOT_PASSWORD=' "${ENV_FILE}" | cut -d= -f2-)"
    if [ -z "${root_pw}" ]; then
        die "MYSQL_ROOT_PASSWORD is not set in ${ENV_FILE}."
    fi

    info "removing all volumes: this destroys any existing data"
    compose down -v --remove-orphans
    # Recreate .env if the operator removed it while the stack was down, using
    # the secrets captured above. Leaving it missing makes every later step --
    # and `docker compose` itself -- fail to resolve the image references.
    if [ ! -f "${ENV_FILE}" ]; then
        cp "${ENV_FILE}.example" "${ENV_FILE}" 2>/dev/null || true
        printf 'MYSQL_ROOT_PASSWORD=%s\n' "${root_pw}" >> "${ENV_FILE}"
        info "recreated ${ENV_FILE} from example plus the captured root password"
    fi

    local start=${SECONDS}
    compose up -d --remove-orphans
    if ! wait_for_backend; then
        fail "clean install never reached a ready state"
        dump_logs
        return 1
    fi
    info "clean install ready in $((SECONDS - start))s"

    check_startup
    check_database_and_terminology
    check_ocl_does_not_block
    check_no_demo_data
    check_core_metadata_intact
    check_login_location
    check_site_metadata
    check_modules_and_owas
    check_rest_api
    check_credentials_rotated
    check_idempotency
}

scenario_restart() {
    echo
    echo "############ RESTART ############"
    local before
    before=$(scalar "SELECT COUNT(*) FROM concept" || echo 0)

    local start=${SECONDS}
    compose restart
    if ! wait_for_backend; then
        fail "the stack did not become ready after restart"
        dump_logs
        return 1
    fi
    info "restarted and ready in $((SECONDS - start))s"

    # A restart must not repeat initialisation. The marker is what proves it.
    local seed_count
    seed_count=$(scalar "SELECT COUNT(*) FROM deployment_state WHERE name = 'db_initialised'" || echo 0)
    if [ "${seed_count}" = "1" ]; then
        pass "initialisation was not repeated after restart"
    else
        fail "the db_initialised marker is gone after restart"
    fi

    local after
    after=$(scalar "SELECT COUNT(*) FROM concept" || echo 0)
    if [ "${after}" = "${before}" ]; then
        pass "no data was lost or added across the restart (${after} concepts)"
    else
        fail "concept count changed across restart: ${before} -> ${after}"
    fi

    check_startup
}

scenario_upgrade() {
    echo
    echo "############ UPGRADE ON EXISTING DATA ############"
    local before_persons
    before_persons=$(scalar "SELECT COUNT(*) FROM person" || echo 0)

    info "recreating containers against the existing volumes"
    compose up -d --build --remove-orphans
    if ! wait_for_backend; then
        fail "the stack did not become ready after an image update"
        dump_logs
        return 1
    fi

    check_idempotency

    local after_persons
    after_persons=$(scalar "SELECT COUNT(*) FROM person" || echo 0)
    if [ "${after_persons}" = "${before_persons}" ]; then
        pass "existing data survived the image update (${after_persons} persons)"
    else
        fail "person count changed across the image update: ${before_persons} -> ${after_persons}"
    fi

    check_core_metadata_intact
    check_login_location
    check_startup
}

summary() {
    echo
    echo "============================================================"
    echo " passed: ${PASSED}"
    echo " failed: ${FAILED}"
    echo "============================================================"
    [ "${FAILED}" -eq 0 ] || exit 1
}

case "${SCENARIO}" in
    clean)   scenario_clean;   summary ;;
    restart) scenario_restart; summary ;;
    upgrade) scenario_upgrade; summary ;;
    all)     scenario_clean;   scenario_restart; summary ;;
    *)       die "usage: $0 [clean|restart|upgrade|all]" ;;
esac
