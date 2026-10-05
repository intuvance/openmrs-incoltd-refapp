#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Re-tag the built images under readable, self-describing names.
#
# WHY
#   The build produces images whose tags mirror the upstream project and encode
#   the variant in a way that has to be looked up to understand:
#
#     openmrs/openmrs-reference-application-3-backend:3.7.1-no-demo
#     openmrs/openmrs-reference-application-3-db:nightly-with-data
#
#   Both are locally built or locally derived artifacts, not upstream pulls, so
#   the `openmrs/openmrs-reference-application-3-*` name is actively misleading:
#   it implies an official build of a known variant, and in the case of
#   `nightly-with-data` it implies a nightly of the dev3 line while the payload
#   is actually pinned release metadata. `docker images` becomes a list you have
#   to interpret rather than one you can read.
#
#   This script adds a second, readable tag to each image. It never removes or
#   overwrites the original tag, so compose, the CI workflows and the documented
#   image references keep resolving exactly as before. Tags are additive, so the
#   two names always point at the same image id and cannot drift.
#
#   `intuvance/openmrs-<component>:<version>` is the readable name, and the
#   `local` variant of the nightly-derived seed keeps saying so:
#
#     intuvance/openmrs-backend:3.7.1
#     intuvance/openmrs-frontend:3.7.1
#     intuvance/openmrs-gateway:3.7.1
#     intuvance/openmrs-db-seed:3.7.1
#
# USAGE
#   deployment/tag-images.sh            # tag whatever .env currently points at
#   deployment/tag-images.sh --check    # report what would be tagged, tag nothing
#
# Only images that already exist locally are tagged. An image that was never
# built (because it was pulled from a registry, or a build was skipped) is
# reported and skipped rather than being silently passed through.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

# Read the image references from .env without sourcing it: .env is a KEY=VALUE
# file the user edits, and sourcing it would execute whatever is in it.
ENV_FILE="${REPO_ROOT}/.env"
if [ ! -f "${ENV_FILE}" ]; then
    echo "tag-images: no .env at ${ENV_FILE}; copy .env.example first" >&2
    exit 1
fi

read_env() {
    # Last assignment wins, matching how docker compose itself resolves .env.
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "${ENV_FILE}" \
        | tail -1 | sed 's/[[:space:]]*$//; s/^"\(.*\)"$/\1/'
}

OMRS_DISTRO_VERSION="$(read_env OMRS_DISTRO_VERSION)"
: "${OMRS_DISTRO_VERSION:=local}"

# A local tag only describes an image that was built here. If the reference in
# .env carries a digest it is pinned to a registry and must not be relabelled as
# a local build.
is_registry_reference() {
    case "$1" in
        *@sha256:*) return 0 ;;
        *) return 1 ;;
    esac
}

# Two input tags share a component name, and the seed image is a data-only
# artifact that is never run as a server, so both get an empty local suffix.
NO_SUFFIX=""

# component:env-var
plan() {
    printf '%s\t%s\t%s\n' \
        "$2" \
        "intuvance/openmrs-$1:${OMRS_DISTRO_VERSION}${NO_SUFFIX}" \
        "${NO_SUFFIX}"
}

declare -a ROWS=()
add_row() { ROWS+=("$(plan "$@")"); }

add_row backend  OMRS_BACKEND_IMAGE
add_row frontend OMRS_FRONTEND_IMAGE
add_row gateway  OMRS_GATEWAY_IMAGE
add_row db-seed  OMRS_DB_SEED_IMAGE
status=0
skipped=0
tagged=0

echo "tagging as intuvance/openmrs-*:${OMRS_DISTRO_VERSION}"

for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r env_var readable suffix <<<"${row}"
    src="$(read_env "${env_var}")"

    if [ -z "${src}" ]; then
        echo "  SKIP  ${env_var} is not set in .env"
        skipped=$((skipped + 1))
        continue
    fi

    if is_registry_reference "${src}"; then
        echo "  SKIP  ${readable} <- ${src}"
        echo "        (digest-pinned registry reference, not a local build)"
        skipped=$((skipped + 1))
        continue
    fi

    if ! docker image inspect "${src}" >/dev/null 2>&1; then
        echo "  SKIP  ${readable} <- ${src}"
        echo "        (no such local image; build or pull it first)"
        skipped=$((skipped + 1))
        status=1
        continue
    fi

    if [ "${CHECK_ONLY}" = true ]; then
        echo "  WOULD ${src}"
        echo "     -> ${readable}"
        continue
    fi

    docker tag "${src}" "${readable}"
    echo "  OK    ${src}"
    echo "     -> ${readable}"
    tagged=$((tagged + 1))
done

echo
if [ "${CHECK_ONLY}" = true ]; then
    echo "check only: nothing was tagged"
else
    echo "tagged ${tagged} image(s), skipped ${skipped}"
    echo
    echo "The readable tags are additive. docker-compose.yml keeps using the"
    echo "references in .env, so nothing changes about which image runs; use the"
    echo "short names when working with docker directly:"
    echo "  docker logs omrs-backend"
    echo "  docker run --rm -it intuvance/openmrs-db-seed:${OMRS_DISTRO_VERSION} sh"
fi

exit "${status}"
