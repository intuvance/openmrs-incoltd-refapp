# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Pre-populated OpenMRS database seed.
#
# This image is the reproducible, version-matched answer to "start production from
# a database that already has CIEL in it". The upstream
# openmrs/openmrs-reference-application-3-db:nightly-with-data image is a nightly
# `docker commit` of a dev3 (3.8.0-SNAPSHOT) run, is amd64-only, pins nothing, and
# ships demo patients plus a publicly known password. This image is built from the
# digest of that image, sanitised by deployment/db/purge-demo-data.sql, and
# re-tagged against the distribution version so that a database and a backend from
# different release lines are never paired.
#
# Build (see .github/workflows/build-db-seed.yml for the full job):
#   docker build -f deployment/db/Dockerfile -t <registry>/openmrs-db-seed:<version> .
# ---------------------------------------------------------------------------
FROM mariadb:10.11.7

# The sanitised dump. Produced by the CI job, which boots a container from the
# upstream pre-populated image, runs the purge script against it, and then exports
# the result into build-context/seed.sql.
#
# seed.sql is produced outside of Docker on purpose: exporting a live MariaDB
# datadir reliably needs a clean shutdown, whereas a logical dump does not.
COPY seed.sql /openmrs-seed/seed.sql

COPY purge-demo-data.sql /openmrs-seed/purge-demo-data.sql
COPY seed.sh /usr/local/bin/seed.sh

# Documentation that travels with the artifact, so anyone who inspects the image
# can see exactly what was removed and what was preserved.
COPY README.md /openmrs-seed/README.md

# This image is data-only: it is never run as a server. Refuse to be started so a
# mistake cannot quietly bring up a second, unrotated database.
ENTRYPOINT ["/bin/false"]
CMD ["database seed image: not intended to be run as a server"]
