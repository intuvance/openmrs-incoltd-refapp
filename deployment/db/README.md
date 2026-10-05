# Pre-populated database seed

`seed.sql` — a sanitised logical dump of a fully started OpenMRS O3 Reference
Application database. Produced by `.github/workflows/build-db-seed.yml`, never
committed.

## What it contains

* the OpenMRS core schema, with every Liquibase changeset from every module applied
* the CIEL concept reference source and its mappings (`concept_reference_map`)
* the core concepts, concept sets and concept metadata that O3, order entry, forms,
  REST and FHIR address by hard-coded UUID
* the core Reference Application metadata: locations, location tags, visit types,
  encounter types, encounter roles, drugs, order types, programs, forms, roles and
  privileges

## What it does not contain

* sample patients, persons, names, identifiers
* sample encounters, visits, observations, orders, program enrolments
* the FHIR and search-index copies derived from them
* the demo application users (`doctor`, `nurse`, `clerk`, `technician`, `daemon`, …)

Demo clinical data is removed by `purge-demo-data.sql` before the dump is taken.
Core *metadata* is deliberately preserved even where the same upstream package
supplied it — see the header of that file for exactly why.

## Why not just use the upstream image directly

`openmrs/openmrs-reference-application-3-db:nightly-with-data` is the mainstream
pre-populated image and is what this seed is derived from. It is not usable as a
production default as published:

| Property | Upstream `nightly-with-data` | This image |
|---|---|---|
| Release line | nightly `main` (3.8.0-SNAPSHOT), not matched to a release tag | tagged with the distribution version |
| Pinned | mutable tag, overwritten nightly | digest-pinned in `.env` |
| Architectures | amd64 only | inherited from the pinned `mariadb` base (multi-arch) |
| Demo data | present (56 persons, 6830 obs, demo users) | removed |
| Database password | fixed, publicly known, and `MYSQL_*` is ignored at runtime | revoked and rotated on first start |
| Origin | `docker commit` of a running container | `mysqldump` of a cleanly shut-down container |

Pairing that database with a 3.7.x backend also puts OpenMRS Liquibase into an
unknown upgrade position. This image removes that risk by construction: the CI
job builds it from the same commit that builds the backend.

## Credentials

There are none. `seed.sh` revokes the seed image's account and creates a
least-privilege account from deployment secrets on first start.
