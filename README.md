# Intuvance OpenMRS O3 Distribution

A production-oriented, mainstream-compatible build of the
[OpenMRS O3 Reference Application](https://o3.openmrs.org).

The goal is a clean, reproducible, deployable distribution that keeps the official
Reference Application's metadata contracts intact while adding a properly
curated site configuration layer, a pre-populated terminology foundation, and
offline-capable operation.

**Upstream compatibility is a first-class requirement.** Nothing in this
repository replaces OpenMRS, O3, the Initializer, the official content packages or
CIEL. Site-specific behaviour is expressed as configuration, then as a content
package, then as a module — in that order — and only then as custom code.

---

## Table of contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Repository structure](#repository-structure)
- [Configuration ownership](#configuration-ownership)
- [Building](#building)
- [Running](#running)
- [Database and CIEL](#database-and-ciel)
- [Content packages](#content-packages)
- [Modules](#modules)
- [OWAs](#owas)
- [Frontend](#frontend)
- [Local and offline deployment](#local-and-offline-deployment)
- [Production deployment](#production-deployment)
- [Security](#security)
- [Upgrades](#upgrades)
- [Observability](#observability)
- [Testing](#testing)
- [Custom modules and AI integration](#custom-modules-and-ai-integration)
- [Troubleshooting](#troubleshooting)
- [Upstream documentation](#upstream-documentation)

---

## Architecture

```text
                 UPSTREAM OPENMRS
                       │
                       ▼
       Mainstream O3 Reference Application
                       │
                       ▼
          Pre-populated Core Database
             CIEL + Core Metadata
                       │
                       ▼
          Official Core Content Package
         org.openmrs.content:referenceapplication
                       │
                       ▼
       Local/Site Configuration Layer
   io.github.miirochristopher:intuvance-siteconfiguration
                       │
                       ▼
       Custom Modules + Local Extensions
                       │
                       ▼
             Production Distribution
```

Concretely, the running system is four containers and one one-shot job:

```text
        ┌──────────────────────────────────────────┐
        │             gateway (nginx)              │  TLS termination, only
        │                                          │  published port
        └───────────────┬──────────────────────────┘
                        │
          ┌─────────────┴─────────────┐
          ▼                           ▼
   ┌──────────────┐           ┌───────────────┐
   │  frontend    │           │   backend     │  OpenMRS WAR, 30 modules,
   │  (nginx/O3)  │           │  + Initializer│     site + core config
   └──────────────┘           └───────┬───────┘
                                      │
                         ┌────────────┴────────────┐
                         │                         │
                   ┌─────▼──────┐          ┌───────▼───────┐
                   │  db-init   │          │      db       │
                   │ (one-shot) │          │  (MariaDB)    │
                   └────────────┘          └───────────────┘
```

`db-init` seeds the pre-populated database and rotates credentials, then exits.
The backend waits for it to complete successfully, so OpenMRS never starts against
a database that lacks CIEL.

---

## Prerequisites

| Requirement    | Version        | Notes                                                                              |
| -------------- | -------------- | ---------------------------------------------------------------------------------- |
| Docker Engine  | 24+            | with the Compose V2 plugin                                                         |
| Docker Compose | 2.20+          | `docker compose`, not `docker-compose`                                             |
| JDK            | 21             | only for building outside Docker                                                   |
| Maven          | 3.9+           | only for building outside Docker                                                   |
| Architecture   | amd64 or arm64 | the upstream pre-populated image is amd64-only; see [Database](#database-and-ciel) |

`docker compose` reads `.env` automatically once it exists. Copy the template
first:

```bash
cp .env.example .env
```

---

## Repository structure

```text
.
├── pom.xml                     reactor; the `distro` profile builds the
│                               content packages and then the distro
├── Dockerfile                  builds the backend image (WAR, modules, OWAs, config)
├── docker-compose.yml          the production stack
├── docker-compose.override.yml local development: build images from source
├── docker-compose.ssl.yml      TLS overlay
├── docker-compose.grafana.yml  monitoring overlay
├── .env.example                every tunable and every secret, documented
│
├── distro/                     the OpenMRS distribution definition
│   ├── pom.xml                 ALL module and content package versions
│   ├── distro.properties       with demo content
│   ├── distro-no-demo.properties  without demo content (production)
│   └── version-rules.xml
│
├── content-packages/
│   └── referenceapplication/   THE SITE CONFIGURATION SOURCE OF TRUTH
│       ├── content.properties  package identity, ordering, variables
│       ├── pom.xml             produces the content zip
│       └── configuration/
│           ├── backend_configuration/   applied by the Initializer
│           └── frontend_configuration/  read by O3
│
├── deployment/                 deployment-specific concerns only
│   ├── db/
│   │   ├── Dockerfile          builds the pre-populated seed image
│   │   ├── seed.sh             idempotent one-shot seed + credential rotation
│   │   ├── purge-demo-data.sql strips demo data, preserves core metadata
│   │   └── README.md           what the seed contains and why
│
├── frontend/                   O3 assembly
├── gateway/                    nginx reverse proxy
├── monitoring/                 Prometheus, Loki, Grafana
├── tests/
│   ├── acceptance/             startup, restart and upgrade acceptance tests
│   ├── e2e/                    browser tests
│   └── ssl/                    certificate tests
│
└── docs/                       SSL and operational guides
```

---

## Configuration ownership

This separation is the core maintainability guarantee of the distribution. Nothing
belongs in the wrong layer.

| Layer                  | Location                                             | Owner                  | Change cadence  |
| ---------------------- | ---------------------------------------------------- | ---------------------- | --------------- |
| **Upstream / core**    | `distro/pom.xml`, `distro.properties` module entries | OpenMRS upstream       | on upgrade      |
| **Core content**       | `org.openmrs.content:referenceapplication`           | OpenMRS upstream       | on upgrade      |
| **Site configuration** | `content-packages/referenceapplication/`             | **this repository**    | per site        |
| **Deployment**         | `docker-compose*.yml`, `deployment/`, `.env`         | this repository        | per environment |
| **Secrets**            | `.env` (gitignored) or Docker secrets                | the operator           | never in Git    |
| **Extensions**         | custom modules                                       | their own repositories | independently   |

Rules that follow from the table:

- Site metadata is **only** ever added under
  `content-packages/referenceapplication/configuration/`. It is not scattered into
  Dockerfiles, SQL, Java or frontend source.
- Nothing in the site layer is ever written _into_ the official content package.
  The SDK installs each package into its own namespace
  (`openmrs_config/<domain>/<namespace>/`), so the two coexist and neither
  overwrites the other.
- Demo clinical data is never a source of production metadata. See
  [Content packages](#content-packages).

---

## Building

### Everything, with Docker (recommended)

```bash
docker compose build
```

This builds the backend image, which internally runs:

```bash
mvn -Pdistro install
```

The reactor builds `content-packages/` **before** `distro/`, because the OpenMRS
SDK resolves content packages as Maven artifacts and therefore needs the site
package in the local repository before the distro module runs.

### Just the Maven build

```bash
mvn clean install -Pdistro
```

To build the distribution without the demo content package, which is what
production uses:

```bash
mvn clean install -Pdistro -Ddistro-omit-demo
```

or point the SDK at `distro/distro-no-demo.properties` directly.

### Output

The assembled distribution lands in `distro/target/sdk-distro/web/`:

```text
openmrs_core/openmrs.war
openmrs_modules/         *.omod
openmrs_owas/            *.owa
openmrs_config/          content package configuration for the Initializer
openmrs-distro.properties
```

### Version pinning

Nothing floats. Every module version, content package version and platform
version is an explicit property in `distro/pom.xml`. Container images are pinned
by digest in `.env`. To move a dependency, change one property and rebuild.

---

## Running

```bash
cp .env.example .env
$EDITOR .env                 # set OMRS_DB_PASSWORD and MYSQL_ROOT_PASSWORD
docker compose up -d
```

| Surface          | URL                                          |
| ---------------- | -------------------------------------------- |
| O3 frontend      | <http://localhost:8080/openmrs/spa>          |
| Legacy UI / REST | <http://localhost:8080/openmrs>              |
| Health           | <http://localhost:8080/openmrs/initialsetup> |

First startup on a seeded database takes a few minutes: the Initializer applies
every content package. It is bounded work, not a download — see
[CIEL/OCL](#database-and-ciel).

```bash
docker compose ps
docker compose logs -f backend
docker compose down            # stop, keep data
docker compose down -v         # stop, DESTROY all data
```

### Container names

Every service declares an explicit `container_name`, so the containers can be
addressed directly instead of through Compose's generated names:

| Service     | Container        |
| ----------- | ---------------- |
| `gateway`   | `omrs-gateway`   |
| `frontend`  | `omrs-frontend`  |
| `backend`   | `omrs-backend`   |
| `db`        | `omrs-db`        |
| `db-init`   | `omrs-db-init`   |

```bash
docker logs -f omrs-backend
docker exec -it omrs-db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" openmrs
```

### Volume names

Volumes carry the same `OMRS_NAME_PREFIX`, so `docker ps` and `docker volume ls`
read consistently. Compose would otherwise prefix them with the project name —
derived from this directory, long, truncated, and different on every machine or
checkout — which produced names like
`openmrs-distro-referenceapplication-371_db-data`:

| Volume               | Holds                                              |
| -------------------- | -------------------------------------------------- |
| `omrs-db-data`       | the clinical record — **back this up**             |
| `omrs-openmrs-data`  | uploads and Initializer config state — back this up |
| `omrs-letsencrypt-data` | TLS private keys — back this up (SSL only)     |
| `omrs-certbot-data`  | ACME challenges (SSL only)                         |

The SSL and Grafana overlays are named the same way, so the whole stack is
recognisable at a glance.

> [!WARNING]
> `OMRS_NAME_PREFIX` is part of the volume name, not just a label. **Changing it
> on an existing deployment creates a second, empty set of volumes instead of
> reusing the live ones**, and the originals are then referenced by nothing. Keep
> it constant, or move the data deliberately. To identify the real volume before
> changing anything:
>
> ```bash
> docker volume ls --filter label=com.docker.compose.project
> docker volume inspect omrs-db-data --format '{{.Labels}}'
> ```

Compose still removes named volumes on `docker compose down -v` (it tracks them
by project label), but `docker volume rm` needs the exact name.

Set `OMRS_NAME_PREFIX` to run a second copy of the stack on one host, e.g.
`OMRS_NAME_PREFIX=omrs-staging`.

### Readable image names

The images carry upstream-style tags (`openmrs/openmrs-reference-application-3-backend:3.7.1-no-demo`),
which obscure the fact that they are locally built and have to be looked up to
interpret. After a build, add short, self-describing tags:

```bash
deployment/tag-images.sh            # tag the images .env points at
deployment/tag-images.sh --check    # report what would be tagged, tag nothing
```

| Built as                                          | Tagged as                        |
| ------------------------------------------------- | -------------------------------- |
| `openmrs/openmrs-reference-application-3-backend:3.7.1-no-demo` | `intuvance/openmrs-backend:3.7.1` |
| `openmrs/openmrs-reference-application-3-frontend:3.7.1` | `intuvance/openmrs-frontend:3.7.1` |
| `openmrs/openmrs-reference-application-3-gateway:3.7.1` | `intuvance/openmrs-gateway:3.7.1` |
| `openmrs-db-seed:local`                           | `intuvance/openmrs-db-seed:3.7.1` |

The tags are additive: the original references are kept, so `docker-compose.yml`,
the CI workflows and any documentation pointing at them keep resolving to the
same image id. Digest-pinned registry references are skipped rather than
relabelled, because a registry image is not a local build.

---

## Database and CIEL

### The requirement

OpenMRS, O3 and order entry reference a large number of concepts by hard-coded
UUID. If those concepts are absent, the application starts but is subtly broken:
forms render empty, order sets resolve to nothing, dashboards break. The fix is to
start from a database that already has them, not to download terminology during
first boot.

### How this distribution does it

`db-init` restores `seed.sql` from `OMRS_DB_SEED_IMAGE` before the backend starts.
That seed is a sanitised logical dump of a fully started Reference Application
database, containing CIEL, the core concepts, the core concept sets and the core
Reference Application metadata.

The seed is built by [`.github/workflows/build-db-seed.yml`](.github/workflows/build-db-seed.yml)
from the same commit as the backend, so a database and a backend from different
release lines are never paired.

### Why not the upstream `-with-data` image directly

`openmrs/openmrs-reference-application-3-db:nightly-with-data` is the mainstream
pre-populated image, and this distribution derives its seed from it. It is not
usable as a production default as published:

| Property          | Upstream `nightly-with-data`                   | This distribution's seed             |
| ----------------- | ---------------------------------------------- | ------------------------------------ |
| Release line      | nightly `main` (3.8.0-SNAPSHOT)                | tagged with the distribution version |
| Pinned            | mutable tag, overwritten nightly               | digest-pinned in `.env`              |
| Architectures     | amd64 only                                     | multi-arch                           |
| Demo data         | present                                        | removed by `purge-demo-data.sql`     |
| Database password | fixed and public; `MYSQL_*` ignored at runtime | revoked and rotated on first start   |
| Origin            | `docker commit` of a live container            | `mysqldump` after a clean shutdown   |

The amd64-only constraint matters if you develop on Apple Silicon: use the
release-matched seed image rather than the upstream one.

### Building the seed yourself

Useful for air-gapped builds, or to refresh terminology:

```bash
docker run -d --name seed-source \
  -e MYSQL_ROOT_PASSWORD=openmrs \
  openmrs/openmrs-reference-application-3-db:nightly-with-data
until docker exec seed-source healthcheck.sh --connect --innodb_initialized; do sleep 2; done

docker exec -i seed-source mariadb -uopenmrs -popenmrs openmrs \
  < deployment/db/purge-demo-data.sql

# The purge's final SELECT reports the counts CI asserts. admin_users and
# daemon_users must both be 1: the daemon user owns the metadata audit trail
# and OpenMRS will not start without it.

docker stop seed-source
docker run --rm --volumes-from seed-source \
  openmrs/openmrs-reference-application-3-db:nightly-with-data \
  mysqldump --no-tablespaces --single-transaction --routines --events \
            -uopenmrs -popenmrs --all-databases > deployment/db/seed.sql

docker build -f deployment/db/Dockerfile -t my-registry/openmrs-db-seed:local deployment/db
```

### Running without the pre-populated seed

```env
OMRS_DB_SEED_ENABLED=false
```

The database is then built entirely from the official Reference Application content
package by the Initializer on first startup. Nothing is downloaded — the
terminology is in the content package. It is slower to first readiness and
reproducible from source alone, which is the right trade-off when you cannot
obtain a prebuilt artifact.

### CIEL and OCL

The distribution does **not** use OCL as a bootstrap mechanism. Specifically:

- `openconceptlab.subscriptionUrl` is deliberately left unset. In
  `openconceptlab` 3.x an unset subscription URL means no subscription is
  scheduled and no remote fetch is ever attempted.
- `openconceptlab.scheduledDays` and `openconceptlab.scheduledTime` are pinned to
  disabled values, so a site that later configures a subscription does not
  accidentally schedule a periodic import.
- The `ocl/` configuration domain contains no `*.zip`. Populating it, or
  populating `openconceptlab.oclLoadAtStartupPath`, turns OCL back into a
  first-boot terminology download — and the module throws during startup if that
  directory holds more than one file.

Consequence: OpenMRS startup is bounded, and the system remains fully usable when
external terminology services are unreachable. If you need OCL, run a
self-hosted instance and opt in with an authenticated subscription; see
`content-packages/referenceapplication/configuration/backend_configuration/ocl/README.md`.

### Demo data vs. core metadata

These are distinguished precisely, and the distinction is load-bearing.

**Removed** — sample patients, persons, names, identifiers, encounters, visits,
observations, orders, program enrolments, FHIR and search-index copies derived
from them, and the demo application users (`doctor`, `nurse`, `clerk`,
`technician`, `daemon`, …).

**Preserved** — everything, including whatever arrived in the same upstream
package: concepts, concept names, concept sources, concept sets, CIEL mappings
(`concept_reference_map`), locations, location tags, address hierarchy, visit
types, encounter types, encounter roles, drugs, order types, programs, forms,
roles, privileges, global properties and all module metadata.

`purge-demo-data.sql` enforces this by selecting tables from `information_schema`
by the clinical foreign keys they carry (`person_id`, `patient_id`,
`encounter_id`, `visit_id`, `obs_id`, `order_id`). No metadata table has one, so
core metadata is preserved by construction rather than by a hand-maintained
exclusion list that could drift.

Do not remove metadata merely because it is not visible in the UI. It is referenced
indirectly by O3, order entry, forms, REST, FHIR, JavaScript applications and
hard-coded UUIDs.

---

## Content packages

| Package                                                  | Role                                  | In production?      |
| -------------------------------------------------------- | ------------------------------------- | ------------------- |
| `org.openmrs.content:referenceapplication`               | the **official** core content package | yes, always, intact |
| `io.github.miirochristopher:intuvance-siteconfiguration` | the site configuration layer          | yes                 |
| `org.openmrs.content:referenceapplication-demo`          | sample clinical data                  | **no**              |

The official core package is never deleted, emptied, replaced or overridden. The
demo package is excluded by building with the `no-demo` Maven profile, which
selects `distro/distro-no-demo.properties` instead of `distro/distro.properties`.
CI passes `MVN_COMMAND=-Pno-demo install`; the `Dockerfile` defaults to the same
profile so a local build matches CI.

This matters beyond demo data. The SDK lays each content package's configuration
out under its own namespace, so a demo-bearing image carries a **second** copy of
the site's configuration under `openmrs_config/<domain>/referenceapplication-demo/`.
Initializer loaders that accept exactly one file per domain then refuse to choose,
and the site's configuration is silently ignored:

```
Multiple disposition files found in the disposition configuration directory
```

Verify a built image carries no demo artifacts:

```bash
docker compose exec backend ls /openmrs/distribution/openmrs_modules | grep referencedemodata
docker compose exec backend ls /openmrs/distribution/openmrs_config
```

Neither output should mention `referencedemodata` or `referenceapplication-demo`.

### Ordering

Ordering is declared, not implicit. The site package's `content.properties`
declares the core package as a dependency:

```properties
content.referenceapplication=1.4.0
```

The OpenMRS SDK honours this (`ContentHelper#getContentPackagesInInstallationOrder`)
and installs the core package first. At runtime the Initializer applies each
namespace idempotently — every handler upserts by UUID or name — so a second pass
is safe and ordering is a convenience rather than a correctness requirement.

### Identity and namespace

The site package deliberately does **not** share the official package's name:

|                       | Official                                        | Site                                         |
| --------------------- | ----------------------------------------------- | -------------------------------------------- |
| artifactId            | `referenceapplication`                          | `intuvance-siteconfiguration`                |
| Initializer namespace | `referenceapplication`                          | `siteconfiguration`                          |
| Installed to          | `openmrs_config/<domain>/referenceapplication/` | `openmrs_config/<domain>/siteconfiguration/` |

Sharing an artifactId would put both packages in the same namespace and make them
overwrite each other. The site namespace also sorts after `referenceapplication`,
so site metadata is applied on top of core metadata.

### What belongs in the site package

Everything site-specific, under
`content-packages/referenceapplication/configuration/backend_configuration/`:

```text
addresshierarchy/        ampathforms/             appointmentservicedefinitions/
appointmentservicetypes/ appointmentspecialities/ autogenerationoptions/
attributetypes/          cohorttypes/             conceptclasses/
conceptreferencerange/   concepts/                conceptsources/
dispositions/            drugs/                   encounterroles/
encountertypes/          fhirconceptsources/      globalproperties/
idgen/                   liquibase/               locations/
locationtags/            metadatasetmembers/      metadatasets/
metadatasharing/         metadatatermmappings/    ocl/
orderfrequencies/        patientidentifiertypes/  personattributetypes/
privileges/              programs/                programworkflows/
relationshiptypes/       roles/                   visittypes/
```

and frontend overrides in `configuration/frontend_configuration/config.json`.

**Before adding a concept, check whether CIEL already has a suitable one.** O3,
order entry and several modules resolve concepts by CIEL UUID; a local duplicate
will not be picked up and will silently diverge from the CIEL concept.

Content package variables let a deployment change a value without a rebuild:

```properties
# content-packages/referenceapplication/content.properties
var.default.login.location=6a679877-1472-4c0e-bdd1-e716f88cbfdb
```

```properties
# distro/distro.properties
var.default.login.location=${site-login-location}
```

### Known issue: placeholder concept UUIDs

`concepts/concepts.csv` contains **3,615 concepts with sequential placeholder
UUIDs** (of the form `108AAAAAAAAAAAAAAA`), alongside 317 with real UUIDs, many of
which are genuine CIEL concepts. The real UUIDs include the ones the O3 frontend
configuration depends on — `04f6f7e0-…` (Emergency),
`f4620bfa-…` (Not Urgent), `51ae5e4d-…` (Waiting) — so the CIEL-facing part of the
package is sound.

The placeholders load correctly but carry a specific risk: if any of them
duplicates a CIEL concept, no O3 form, order set or dashboard will ever resolve it,
because those look concepts up by CIEL UUID. A duplicate is silent — nothing errors,
the value simply never appears.

This is a clinical-vocabulary decision, so it is **reported, not changed** here.
`tests/acceptance/validate-content-metadata.py` prints the count on every build;
use `--strict` to make it fail instead.

```bash
tests/acceptance/validate-content-metadata.py
```

Triaging it is worth doing before go-live: for each placeholder, check whether CIEL
already has the concept, and if so replace the row's UUID with the CIEL one.

One concept, `Education currently received`, had a 7-character UUID that could not
be repaired. It is quarantined in `concepts/concepts.quarantine.csv` rather than
given an invented UUID, so the gap is visible instead of silently producing a
concept nothing can reference. Restore it with the real CIEL UUID once confirmed.

The validator also rejects, in CI, metadata that would fail at startup: malformed
UUIDs, UUIDs duplicated within a domain, `${var}` references in global properties
that `content.properties` does not declare, and a `*.zip` left in `ocl/`. Four
malformed UUIDs already found this way (three missing hyphens, one `l`/`1`
transcription error) were repaired; the repairs were checked against every other
declared UUID to confirm no collision.

---

## Modules

Thirty upstream modules are declared in `distro/pom.xml` and
`distro/distro.properties`, covering the Reference Application, O3 backend
requirements, order entry, reporting, appointments, beds, stock, billing, FHIR and
REST.

| Area          | Modules                                                                                |
| ------------- | -------------------------------------------------------------------------------------- |
| Core plumbing | `initializer`, `webservices.rest`, `fhir2`, `idgen`, `legacyui`, `authentication`      |
| Clinical      | `o3forms`, `emrapi`, `event`, `ordertemplates`, `patientflags`, `attachments`, `queue` |
| Facility      | `bedmanagement`, `appointments`, `stockmanagement`, `billing`, `tasks`                 |
| Reporting     | `reporting`, `reportingrest`, `calculation`, `htmlwidgets`, `serialization.xstream`    |
| Terminology   | `openconceptlab`, `metadatamapping`                                                    |
| Other         | `addresshierarchy`, `patientdocuments`, `cohort`, `teleconsultation`                   |

To add a custom module, declare it in `distro/pom.xml` (dependency, `provided`
scope) and `distro/distro.properties`:

```properties
omod.mymodule=${mymodule.version}
omod.mymodule.groupId=com.example   # only if not org.openmrs.module
```

Then bump `distro/version-rules.xml` if the module needs a minimum platform
version. Nothing else changes: the SDK downloads the omod, `build-distro` places
it in `openmrs_modules/`, and the Dockerfile copies that into the image.

### Required-module guarantees

`initializer`, `webservices.rest`, `fhir2` and `ocl` are asserted individually by
the acceptance test, because a distro that starts without one of them looks
healthy and fails in specific, confusing ways.

---

## OWAs

This distribution ships **no OWAs**. The packaging path is present and correct if
one is ever added.

When you add a custom OWA:

1. Publish it as a Maven artifact. The SDK downloads OWAs from Maven only — there
   is no local-source path and no `addOWAs` element in `openmrs-sdk-maven-plugin`.
2. Declare it in `distro.properties`:

   ```properties
   owa.myowa=${myowa.version}
   owa.myowa.groupId=com.example     # default is org.openmrs.web
   ```

3. `build-distro` places it at `openmrs_owas/myowa-<version>.owa` and the
   `Dockerfile` copies that directory into the image.

Do not assume that adding an OpenMRS module installs a corresponding OWA. It does
not: modules ship Java resources, OWAs are separate artifacts with a separate
lifecycle. Verify the resulting URL explicitly —
`http://localhost:8080/openmrs/openmrs/spa/myowa/` — and add it to the acceptance
test.

---

## Frontend

`frontend/` assembles the O3 shell; `frontend/spa-assemble-config.json` pins each
`@openmrs/esm-*` package to an exact version, so the frontend build is
reproducible.

Frontend configuration is a _site_ concern and lives in the site content package:

```text
content-packages/referenceapplication/configuration/frontend_configuration/config.json
```

The Initializer writes it to
`/openmrs/data/configuration/frontend_configuration/config.json`, and the
frontend serves it as a SPA config URL. Point `OMRS_SPA_CONFIG_URLS` at the file
the Initializer actually wrote — `/openmrs/spa/config-core.json` by default. If the
frontend shows defaults where you expect site branding, this value is the first
thing to check.

Do not hand-copy config files into a running container. A change that does not
come from the content package is lost on the next rebuild.

---

## Local and offline deployment

Core clinical workflows require no internet access at runtime:

| Dependency                | Required at runtime?                                                 |
| ------------------------- | -------------------------------------------------------------------- |
| OCL / terminology service | no — `subscriptionUrl` is unset                                      |
| Cloud AI                  | no — see [Custom modules and AI](#custom-modules-and-ai-integration) |
| External auth provider    | no — OpenMRS authentication is local                                 |
| CDN / remote JavaScript   | no — O3 assets are served from the frontend container                |
| `apt` / `pip` / `npm`     | no                                                                   |

To deploy inside a facility network:

1. Build the images on a connected host and export them:

   ```bash
   docker compose build
   docker save -o openmrs-distro.tar \
     $(docker compose config --images | tr '\n' ' ')
   ```

2. Transfer `openmrs-distro.tar` and this repository, then on the facility host:

   ```bash
   docker load -i openmrs-distro.tar
   docker compose up -d
   ```

If you must build inside the air gap, prime the Maven and npm caches on a
connected host (`~/.m2/repository` and `frontend/node_modules`) and copy them
across; `mvn -o` and `npm ci --offline` will then work.

---

## Production deployment

1. Enable TLS by adding the overlay to `.env`:

   ```env
   COMPOSE_FILE=docker-compose.yml:docker-compose.ssl.yml
   SSL_MODE=prod
   CERT_WEB_DOMAINS=openmrs.example.org
   CERT_CONTACT_EMAIL=admin@example.org
   OMRS_REST_PROXY=https://openmrs.example.org/openmrs
   ```

2. Generate and set the secrets:

   ```bash
   openssl rand -base64 32   # OMRS_DB_PASSWORD
   openssl rand -base64 32   # MYSQL_ROOT_PASSWORD
   ```

3. Pin every image by digest, and make sure `OMRS_DB_SEED_IMAGE` is the seed built
   from this same release line.

4. Start, and verify with the acceptance test:

   ```bash
   docker compose up -d
   tests/acceptance/startup-acceptance.sh
   ```

5. Back up both volumes. `db-data` holds the clinical record; `openmrs-data` holds
   uploaded files and the Initializer's configuration checksums.

   ```bash
   docker compose exec -T db mariadb-dump -uroot -p"${MYSQL_ROOT_PASSWORD}" \
     --single-transaction --routines --events openmrs > openmrs-$(date +%F).sql
   ```

See [docs/ssl.md](docs/ssl.md) for the full certificate guide and
[docs/operations.md](docs/operations.md) for the runbook.

---

## Security

- **No committed credentials.** `.env` is gitignored and excluded from the Docker
  build context. The two password variables have deliberately unusable defaults,
  so a deployment that forgot to set them fails to start rather than coming up
  with a public password.
- **The seed's password is revoked.** The upstream pre-populated image ships a
  fixed, publicly known database password, and its entrypoint ignores `MYSQL_*`
  once the datadir is initialised. `seed.sh` therefore drops that account and
  creates a least-privilege replacement from your secrets. The acceptance test
  asserts the old password no longer works.
- **Least privilege.** The OpenMRS account is scoped to the `openmrs` schema. It
  holds DDL rights only because `OMRS_CONFIG_AUTO_UPDATE_DATABASE` is enabled.
- **Nothing is published but the gateway.** Neither the database nor the backend
  declares a `ports` entry; both are reachable only on the internal compose
  network. The acceptance test asserts this.
- **HTTPS.** Terminated at the gateway. Set `OMRS_REST_PROXY` so generated links
  use `https://`.
- **Session hardening.** Set `OMRS_SESSION_TIMEOUT`. When TLS terminates at the
  gateway on the same host, enable secure cookies via the reverse proxy
  configuration in `gateway/`.
- **Demo users are gone.** The default `admin`/`Admin123` credentials must be
  changed on first login; the demo accounts (`doctor`, `nurse`, …) do not exist.

---

## Upgrades

The distribution is designed so that upgrading OpenMRS is a version bump, not a
migration project. Nothing in OpenMRS core Java, the database schema, or the O3
source is modified.

```text
upstream version  +  modules  +  content package  +  site configuration
```

### Bumping a module or the platform

1. Change the version property in `distro/pom.xml`.
2. Run `mvn clean install -Pdistro`.
3. If a new content package version is needed, bump `reference-content.version`
   **and** re-check the site package's `content.referenceapplication` pin.
4. `docker compose build && docker compose up -d`.
5. Run `tests/acceptance/startup-acceptance.sh upgrade`.

Liquibase applies module schema changes automatically
(`OMRS_CONFIG_AUTO_UPDATE_DATABASE=true`).

### Bumping OpenMRS itself

1. Change `openmrs.version` and the `Dockerfile` base image together.
2. Rebuild the seed image for the new line. A database from an older release line
   will put Liquibase into an unknown upgrade position; this is the main reason
   the seed is version-matched rather than reused.
3. For a major platform upgrade, dump and restore into a fresh volume rather than
   upgrading in place — see [docs/operations.md](docs/operations.md).

### Upgrading an existing deployment

Existing volumes are reused, not recreated. `db-init` detects the
`db_initialised` marker and exits immediately, so no initialisation is repeated
and no data is touched. The acceptance test's `upgrade` scenario asserts that the
person count is unchanged across an image update.

**Never** use `docker compose down -v` against production. It destroys the
`omrs-db-data` volume.

---

## Observability

Health checks, and what each one actually proves:

| Service    | Check                                           | Proves                                                                   |
| ---------- | ----------------------------------------------- | ------------------------------------------------------------------------ |
| `db`       | `healthcheck.sh --connect --innodb_initialized` | MariaDB is accepting connections with a usable InnoDB                    |
| `backend`  | `GET /openmrs/initialsetup`                     | the WAR is deployed, the datasource is reachable and the modules started |
| `frontend` | `GET /`                                         | the O3 shell is being served                                             |
| `gateway`  | `GET /nginx-health`                             | routing is up                                                            |
| `db-init`  | exit code                                       | initialisation completed; a non-zero exit blocks the backend             |

The backend check deliberately targets `/openmrs/initialsetup` rather than a TCP
port: a 200 there means startup is genuinely complete, not merely that a process
is alive.

Startup failures are never swallowed. `db-init` exits non-zero and the backend
does not start, and the acceptance test dumps the backend, `db-init` and `db` logs
on failure.

Logs are prefixed by service and by phase:

```text
[db-init] restoring the pre-populated database from /openmrs-seed/seed.sql
[db-init] credentials rotated
[db-init] database already initialised; skipping seed and credential rotation
```

so a failure is attributable to the database, the seed job, a module, the
Initializer or the frontend without cross-reading logs.

For Prometheus, Loki and Grafana:

```bash
docker compose -f docker-compose.yml -f docker-compose.grafana.yml up
```

---

## Testing

```bash
# everything: clean install, then restart
tests/acceptance/startup-acceptance.sh all

# individually
tests/acceptance/startup-acceptance.sh clean     # docker compose down -v && up
tests/acceptance/startup-acceptance.sh restart   # must not re-initialise
tests/acceptance/startup-acceptance.sh upgrade   # existing volumes, new images
```

The acceptance test asserts the behaviours the distribution is accountable for,
not just that containers started: concept and CIEL mapping counts, absence of demo
data, presence of core metadata, the Login Location tag _and_ the `login.location`
property _and_ that it resolves, OCL not being mid-import, module load errors,
REST and FHIR reachability, that the seed password no longer works, and that only
the gateway publishes a port.

Content metadata is validated separately, because a defect there surfaces as a
startup failure or — worse — as a concept nothing can reference:

```bash
tests/acceptance/validate-content-metadata.py           # warnings only
tests/acceptance/validate-content-metadata.py --strict  # placeholders fail too
```

`tests/acceptance/startup-acceptance.sh clean` is destructive and says so before
running.

Browser tests: `tests/e2e/README.md`. CI: `.github/workflows/`.

---

## Custom modules and AI integration

### Where custom code belongs

```text
OpenMRS Core
    ├── Reference Application        upstream, unmodified
    ├── O3                          upstream, unmodified
    ├── Standard Modules            upstream
    ├── Terminology / OCL           upstream
    ├── Reporting                   upstream modules, site reports as content
    ├── Expert System / AI          custom module
    └── Other Intuvance modules     custom modules
```

Prefer, in order: upstream capability → configuration → an extension module →
a content package → custom code. Custom modules stay independently maintainable
and are consumed by declaring a version in `distro/pom.xml` and
`distro/distro.properties`, exactly like any upstream module.

### AI must fail gracefully

The supported architecture is local:

```text
OpenMRS
   │
   ▼
Expert System Module
   │
   ▼
AI / Tool Gateway
   │
   ▼
Local LLM Runtime (Ollama or compatible)
```

Requirements for any AI module added here:

- **Never** hard-code an OpenAI endpoint or API key. Endpoint and credential come
  from environment variables or global properties.
- The AI layer must be **optional at runtime**. If the model is unavailable, log
  an unavailable status, surface it in the UI, and carry on. OpenMRS startup must
  not depend on the model being reachable.
- No core clinical workflow may call the AI layer synchronously. A slow or dead
  model must not be able to delay a consultation form.
- Degrade per feature, not per install: a clinical user who never touches the AI
  feature should not notice it exists.

A failing AI call should look like a timeout on an optional widget, not like a
500 from the backend.

**`FetchNotFoundException: Entity 'org.openmrs.User' with identifier value '2' does not exist`**
The seeded database is missing the `daemon` system user, which owns the
metadata audit trail, so every metadata read fails. It floods the log from the
location, party and location-tree synchronisers through to the Initializer's CSV
loads — tens of thousands of lines that all have this one cause.

The seed is built by purging the upstream image, and a purge that deletes the
`daemon` user produces a database which restores cleanly and only fails at
runtime. Confirm and check:

```bash
docker compose exec db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" openmrs -e \
  "SELECT user_id, username FROM users;
   SELECT COUNT(*) AS dangling FROM concept
     WHERE creator <> 0 AND creator NOT IN (SELECT user_id FROM users);"
```

`daemon` must be present and `dangling` must be 0. If not, rebuild the seed
(see [Building the seed yourself](#building-the-seed-yourself)). Note that
`db-init` is guarded by the `deployment_state` marker, so it will not re-seed an
existing volume — recreate it deliberately:

```bash
docker compose down -v && docker compose up -d   # destroys all data
```

`purge-demo-data.sql` now excludes `daemon` from the demo-user list, asserts the
surviving system users in its verification `SELECT`, and fails loudly if any
`creator` / `changed_by` / `retired_by` column still references a deleted user.

**A 500 from `/openmrs/initialsetup` shortly after start**
`StartupErrorFilter` serves this page while the context is still initialising.
It resolves on its own once startup completes; check again rather than treating
it as a failure. A 200 there is the readiness signal.

**The gateway container is `unhealthy` but traffic works**
The healthcheck probes `/nginx-health`, which the gateway serves itself (see
`gateway/default.conf.template`). If nginx answers 404 for it, the running
gateway image predates that location — rebuild it:

```bash
docker compose build gateway && docker compose up -d gateway
```

**`ClassNotFoundException` for an appointments scheduler task on first boot**
```
Failed to schedule task Reminder of scheduled appointment
Caused by: ClassNotFoundException:
  org.openmrs.module.appointments.scheduler.tasks.ReminderForAppointment
```
Expected on the **first** startup only, and harmless — ignore it. It is a
startup-ordering race, not a version mismatch and not a data problem:

- The class *is* present. It lives in `lib/appointments-api-*.jar` inside
  `appointments-<version>.omod`, and the names in `scheduler_task_config` match it
  exactly.
- On first boot OpenMRS cycles the appointments module while the scheduler runs,
  so the class is briefly unresolvable. Later boots start with module state
  already settled and log nothing.

Confirm it is the transient and not a real mismatch:

```bash
docker compose restart backend
docker compose logs backend | grep -c ReminderForAppointment   # 0 after a restart
```

Do **not** delete the `scheduler_task_config` rows to silence it. They are
legitimate metadata for the bundled module; removing them permanently disables
appointment reminders and missed/complete marking, and the module only recreates
them against a fresh database.

**Address hierarchy configuration not loaded**
```
Address hierarchy configuration file appears invalid, skipping the loading process:
  /openmrs/data/configuration/addresshierarchy/addressConfiguration.xml
```
The file is present but one directory too deep. The SDK assembles
`openmrs_config` with each content package under its own subdirectory
(`addresshierarchy/siteconfiguration/addressConfiguration.xml`), while the
addresshierarchy module resolves its config with a plain
`new File(dir + "/" + name)` and performs no directory search. The `Dockerfile`
overlays the site's `addresshierarchy` files flat to satisfy it. If this error
appears, the running image predates that change — rebuild the backend.

**Multiple disposition files found in the disposition configuration directory**
```
Multiple disposition files found in the disposition configuration directory.
```
The site's configuration is duplicated because the image was built with the demo
profile, which adds `openmrs-content-referenceapplication-demo` and therefore a
second copy of `dispositionConfig.json` under a second namespace.
`DispositionsLoader` accepts exactly one file per domain and refuses to choose
between them, so the site's file is silently ignored.

The `Dockerfile` builds with `-P distro,no-demo` so this cannot happen. If you see
this error, the running image was built without that profile — rebuild it. Check
with:

```bash
docker compose exec backend ls /openmrs/distribution/openmrs_config/dispositions
docker compose exec backend ls /openmrs/distribution/openmrs_modules | grep referencedemodata
```

Neither should exist. Note that a flat copy is **not** a valid workaround here:
unlike addresshierarchy, this loader walks the directory recursively and counts
matches, so adding a third copy makes it worse. The duplicate has to be removed at
the source, which is what `no-demo` does.

**`Attribute "moduleId" must be declared for element type "allow"` / `"signatures"`**
Expected, and harmless. It comes from `WEB-INF/dwr-modules.xml`, which OpenMRS
generates at startup with a `moduleId` attribute on `<allow>` and `<signatures>`.
The parser is given an `EntityResolver` that returns an **empty** DTD, so
`moduleId` is validated against nothing and reported as undeclared. The document
still parses — `dwr-modules.xml` keeps all 438 lines and DWR works. This is an
upstream OpenMRS/DWR interaction and is not fixable from this repository; do not
"fix" it by editing `dwr-modules.xml`, since OpenMRS rewrites that file on every
boot.

**`Store limit is 102400 mb` / `Temporary Store limit is 51200 mb`**
Apache ActiveMQ's default `SystemUsage` caps are 100 GB (store) and 50 GB
(temp), and the event module does not expose them as OpenMRS properties, so they
cannot be lowered from `.env`. The warning fires when free disk is below those
caps — it is reporting real capacity pressure, not a misconfiguration.

Check the actual figure before deciding it is cosmetic:

```bash
docker compose exec backend df -h /openmrs/data
```

The fix is disk capacity, not log suppression. If the volume shares a filesystem
with other workloads, give `openmrs-data` its own volume or filesystem so
ActiveMQ's data cannot be starved by unrelated growth.

---

## Troubleshooting

**Startup never finishes / appears to hang on terminology**
It should not, and if it does, that is a regression. Check that
`openconceptlab.subscriptionUrl` is unset:

```bash
docker compose exec db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" openmrs -e \
  "SELECT property, property_value FROM global_property WHERE property LIKE 'openconceptlab%';"
```

Also confirm no archive was left in the `ocl` configuration domain: the OCL module
throws during startup if that directory holds more than one file.

**`db-init` fails with "no seed dump"**
`OMRS_DB_SEED_ENABLED` is `true` but `OMRS_DB_SEED_IMAGE` does not contain
`/openmrs-seed/seed.sql`. Either build the seed (see
[Database](#database-and-ciel)) or set `OMRS_DB_SEED_ENABLED=false` to build the
database from the content package instead.

**`SEVERE ... Unable to create directory for deployment: [.../conf/Catalina/localhost]`**
Tomcat's `HostConfig` creates a per-hostname config directory at startup. The
image runs as uid 1001 while `/usr/local/tomcat/conf` is root-owned, so the
attempt is denied. Harmless for a single-host WAR deployment, and the
`Dockerfile` pre-creates the directory with the runtime owner to silence it. If
you see it, the running image predates that change — rebuild the backend.

**The backend never starts**
By design: it waits for `db-init` to exit 0. Look at
`docker compose logs db-init`, then `docker compose logs backend`.

**`initialsetup` returns 503**
The WAR is deployed but the datasource or a module is not up yet. Check
`docker compose logs backend | grep -iE "error|exception|fatal"` and
`docker compose logs db`.

**Login Location is missing or the login page has no location picker**
Both halves must be present. Assert it directly:

```bash
docker compose exec db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" openmrs -e \
  "SELECT property_value FROM global_property WHERE property='login.location';
   SELECT l.name FROM location l
     JOIN location_tag_map m ON m.location_id = l.location_id
     JOIN location_tag t ON t.location_tag_id = m.location_tag_id
    WHERE t.name='Login Location';"
```

If the tag is present but the property is not, the site content package did not
apply — check that `intuvance-siteconfiguration` is in
`distro/target/sdk-distro/web/openmrs_config/`.

**Forms render empty, order sets resolve to nothing**
Concepts are missing. Check the CIEL mapping count; if it is near zero the seed
did not load:

```bash
docker compose exec db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" openmrs -e \
  "SELECT COUNT(*) FROM concept_reference_map;"
```

**Frontend shows defaults instead of site configuration**
`OMRS_SPA_CONFIG_URLS` does not point at the file the Initializer wrote. Confirm:

```bash
docker compose exec backend ls /openmrs/data/configuration/frontend_configuration/
```

**Everything is fine, then the next `up` re-initialises**
The `db_initialised` marker is gone, which means the `db-data` volume was
replaced. Check for a stray `down -v`.

**`initialsetup` is slow on restart**
`OMRS_CONFIG_SCHEDULER_STARTUP` triggers a search index rebuild on boot. Set it
to `false`; the system is fully usable without it.

**Startup errors are ambiguous**
`tests/acceptance/startup-acceptance.sh` prints the failing check and dumps the
backend, `db-init` and `db` logs together.

---

## Upstream documentation

- [OpenMRS O3](https://o3docs.openmrs.org) — frontend and module development
- [OpenMRS 3 Reference Application](https://www.openmrs.org/) — platform
- [Initializer](https://github.com/mekomsolutions/openmrs-module-initializer) —
  content package format and domains
- [openmrs-sdk-maven-plugin](https://github.com/openmrs/openmrs-sdk) — how
  `distro.properties` is interpreted
- [OpenConceptLab](https://github.com/openmrs/openmrs-module-openconceptlab) —
  terminology integration
- [docs/ssl.md](docs/ssl.md) — certificates
- [docs/operations.md](docs/operations.md) — backup, restore, runbook
