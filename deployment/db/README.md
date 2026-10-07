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

## When the dump is restored, and when it is not

`seed.sh` treats the dump as a fallback, not a startup step. It runs on every
`docker compose up`, and most of the time the correct answer is to do nothing.

The dump is 15 MB and restoring it rewrites every table, which costs about four
minutes of database time. The distro ships a fixed Initializer that no longer
destroys terminology, so a restored database stays correct and there is no
reason to replay it. On a healthy install `db-init` therefore verifies the
terminology and exits in about 13 seconds.

Two things cause a restore:

* **Drift.** Seeded concepts missing, concept reference mappings lost, mappings
  pointing at concepts that no longer exist, the `is_set` flag out of step with
  the `concept_set` rows, or fewer than three concept map types surviving. Any of
  these means drug and lab order entry cannot work, so the dump is replayed. The
  log names the specific failure rather than reporting a bare "failed".
* **A new seed.** The dump's SHA-256 no longer matches the one recorded when it
  was applied. This forces a restore even when the database is intact, which is
  what keeps two fresh builds of the same commit in agreement.

Concepts and mappings an administrator added are deliberately *not* drift: the
manifest records only what the seed installed, so legitimate edits never trigger
a restore.

Set `OMRS_DB_RESTORE_ON_DRIFT=false` to downgrade drift to a warning. That is for
an instance whose terminology has been hand-edited; on any normal install the
restore is the correct action.

### Restoring by hand

The gate needs to know that nothing is connected, because a restore cannot run
alongside open connections and otherwise fails part-way through with a lock
timeout, leaving the database half-written. The compose topology guarantees this
because `backend` depends on `db-init` completing, but a restore triggered by
drift is exactly the case an operator is most likely to run by hand:

```
docker compose stop backend
docker compose run --rm db-init
docker compose up -d backend
```

`OMRS_DB_FORCE_RESTORE=true` overrides the check.

## Tests

`tests/acceptance/test-seed-integrity-gate.sh` exercises the gate's SQL against a
throwaway MariaDB with a miniature schema — no OpenMRS image, no dump, no
backend, so it runs in well under a minute. It covers a healthy install, an
administrator's additions, an already-repaired install, the upstream regression,
partial mapping loss, deleted seeded concepts, dangling mappings, thinned concept
map types, and the `is_set` disagreement. It extracts the SQL from `seed.sh`
itself, so the test and the script cannot drift apart.

`deployment/verify-initializer-package.py` is run by the image build rather than
by a test, because a mismatch is only observable in the assembled omod.

## The Initializer deletes the concept reference mappings

**Fixed.** The distro now ships the Intuvance fork of the Initializer, which does
not do this. The text below is kept because it explains what the archive, the
Liquibase changesets and `verify-terminology.sh` are for, and because an install
created before the swap still needs them.

The seed ships 18,882 rows in `concept_reference_map`. Upstream OpenMRS destroys
almost all of them on the first boot after seeding, and reports nothing.

The cause is `openmrs-module-initializer`. For every concept it loads from a
content package's `concepts.csv`,
`org.openmrs.module.initializer.api.c.MappingsConceptLineProcessor.fill()` does:

```java
if (!CollectionUtils.isEmpty(concept.getConceptMappings())) {
    concept.getConceptMappings().clear();
}
```

Clearing a Hibernate collection of `ConceptMap` deletes every row on flush. The
processor then re-adds only the mappings named in that row's `Same as mappings`
column, and the Intuvance content package populates that column for no concept.
Measured on a clean first run: 18,882 mappings become 724, via ~18,000 individual
`delete from concept_reference_map where concept_map_id = N` statements, none of
them logged above WARN.

The install still starts and the login page still works. What breaks is every
feature that resolves a concept by an external code: drug and lab order entry,
medication workflows, the concept search in the order forms, and FHIR concept
translation. That is why the loss has to be both prevented and verified rather
than noticed.

The `clear()` is unconditional, and the CSV grammar permits one mapping per
column, so 18,882 mappings could not be restated in the content package even in
principle.

### What the distro ships instead

`distro/pom.xml` pins the Initializer to `io.github.intuvance:initializer-omod`
and `distro/distro.properties` sets `omod.initializer.groupId` to match. Both are
load-bearing: the SDK defaults an `omod.*` key to `org.openmrs.module`, so
without the groupId override the build silently resolves the upstream artifact
and the destructive behaviour returns.

The fork parses each line before touching the concept, and only clears when the
line actually declared mappings. A line that declares nothing leaves what the
concept already had; a line that declares something still replaces it wholesale,
so content packages that do author mappings keep the upstream "the CSV wins"
semantics. The deliberate trade-off is that a package can no longer blank out
terminology by omitting a column.

Verified on a clean boot from wiped volumes: 18,882 seeded mappings present, zero
absent by uuid, 18,885 live after the content packages add three of their own,
zero dangling, 13 concept map types in use.

### The fork's `package` declaration

`2.12.1-intuvance.1` is not usable. It derived the omod's `<package>` from its
Maven coordinates, so it declared `io.github.intuvance.initializer` while its
classes were and remain in `org.openmrs.module.initializer`. OpenMRS matches a
`require_module` dependency by package name with no fallback to the module id, so
`patientdocuments` 1.1.0 — which requires `org.openmrs.module.initializer` 2.9.0
— silently refused to start while the Initializer itself ran normally.
`2.12.1-intuvance.2` corrects the declaration.

`deployment/verify-initializer-package.py` asserts the invariant during the image
build, comparing `<package>` against the package of `<activator>`, and fails the
build rather than shipping an image with a module that will not start.

### How it is handled

| Stage | File | Role |
|---|---|---|
| before the backend can boot | `seed.sh` | copies the seed's mappings into `openmrs_concept_map_archive` |
| every boot, from Liquibase | `../content-packages/referenceapplication/configuration/backend_configuration/liquibase/concepts.xml` | keeps the archive current and replays anything missing |
| after the backend is healthy | `verify-terminology.sh` | rebuilds the archive from the seed dump if needed, repairs, then fails the deployment if the install is still not whole |
| CI | `.github/workflows/build-db-seed.yml` | refuses to publish a seed that cannot satisfy the repair |

`openmrs_concept_map_archive` is the reason a legacy deployment can be recovered:
for an install created before any of this existed the mappings are already gone,
so `verify-terminology.sh` falls back to the seed dump that the seed image
carries, and that dump is the only remaining record of what they were.

The replay is `INSERT IGNORE` keyed on uuid, so an administrator who removes a
mapping on purpose will see it come back. That is deliberate — this is
terminology integrity rather than configuration — and retiring one for good means
deleting it from the archive too.
