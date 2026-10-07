# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# OpenMRS O3 Reference Application backend, with the Intuvance site
# configuration content package layered on top of the official core content
# package.
#
# Reproducibility notes
#   * the base images are pinned by tag; pass OPENMRS_CORE_BUILD_TAG to move
#   * every module and content package version lives in distro/pom.xml, so
#     nothing here resolves a floating version
#   * the site content package is built from this repository in the same RUN as
#     the distro, so a clean checkout reproduces the whole distribution
# ---------------------------------------------------------------------------

### Dev stage
# -dev: the SDK's distribution goal runs against this.
FROM openmrs/openmrs-core:2.8.x-dev-amazoncorretto-21 AS dev
WORKDIR /openmrs_distro

# `no-demo` is not optional for this distribution.
#
# The SDK builds the demo profile by default, and it pulls in
# openmrs-content-referenceapplication-demo -- the only source of sample
# patients, encounters, visits, providers, facilities and demo drugs. Leaving it
# in does not merely ship demo data: it also duplicates this site's
# configuration under a second namespace (openmrs_config/<domain>/<namespace>/),
# which breaks Initializer loaders that accept exactly one file per domain.
# Dispositions is the visible case: referenceapplication-demo and
# siteconfiguration both supply dispositionConfig.json, DispositionsLoader
# refuses to choose between them, and the site's file is silently ignored --
# "Multiple disposition files found in the disposition configuration directory".
#
# CI already builds this way (build-backend.yml passes MVN_COMMAND=-Pno-demo).
# Defaulting to the same profile here means a local `docker build` produces the
# image the tag claims, instead of a demo-bearing variant carrying the same
# `-no-demo` tag.
ARG MVN_ARGS="-s /usr/share/maven/ref/settings-docker.xml -U -P distro,no-demo"
ARG MVN_COMMAND="install"

# Build files only, so that the dependency layer is cached independently of the
# metadata content. Changing a CSV invalidates only the final build step.
COPY pom.xml ./
COPY content-packages ./content-packages/
COPY distro ./distro/

ARG CACHE_BUST

# The OpenMRS SDK resolves content packages as Maven artifacts at package time, so
# the site content package has to be installed into the local repository before the
# distro module runs. Reactor order is declared in the root pom.xml (content
# packages first), which is what makes a single `mvn install` sufficient.
#
# Only deploy from the amd64 build.
#
# The ~/.m2 cache mount keeps the ~130 MB platform WAR and the ~30 module
# artifacts across rebuilds. It is a BuildKit cache mount, so it does not affect
# the resulting image contents and does not need to be cleaned.
RUN --mount=type=secret,id=m2settings,target=/usr/share/maven/ref/settings-docker.xml \
    --mount=type=cache,target=/root/.m2/repository \
    if [ "$(arch)" != "x86_64" ]; then MVN_ARGS="$MVN_ARGS -Dmaven.deploy.skip=true"; fi && \
    mvn $MVN_ARGS $MVN_COMMAND

RUN cp /openmrs_distro/distro/target/sdk-distro/web/openmrs_core/openmrs.war /openmrs/distribution/openmrs_core/
RUN cp /openmrs_distro/distro/target/sdk-distro/web/openmrs-distro.properties /openmrs/distribution/

# openmrs_config carries the content package configuration (backend_configuration
# and frontend_configuration) that the Initializer module applies at startup.
#
# The copy below is the SDK's assembled openmrs_config, which nests each content
# package's configuration under a directory named after that package:
#
#   openmrs_config/addresshierarchy/siteconfiguration/addressConfiguration.xml
#
# The addresshierarchy module cannot read that layout. It resolves its config
# file with ConfigDirUtil.getFile(), which is a plain
# `new File(domainDir + "/" + name)` with no directory search, so it looks for
# exactly:
#
#   openmrs_config/addresshierarchy/addressConfiguration.xml
#
# and logs "Address hierarchy configuration file appears invalid, skipping the
# loading process" on every boot when the file is one level too deep. The site
# configuration's address hierarchy is then never applied.
#
# So overlay the site's own backend_configuration on top, flat. This is additive:
# the SDK's tree is still there for every other module that expects the nested
# layout, and only addresshierarchy gets the extra copy it needs.
#
# Note this is deliberately NOT done for dispositions, which superficially looks
# like the same problem. Its loader walks the domain directory recursively and
# accepts exactly one match, so an extra copy makes it worse rather than better;
# duplicates there have to be prevented at the source instead, which is what the
# `no-demo` profile above does. The distinction is in the loader, not the layout.
#
# `frontend_configuration` is NOT delivered by the Initializer: there is no
# FRONTEND_CONFIGURATION domain in its Domain enum, so a content package can
# never write it to /openmrs/data/configuration/frontend_configuration/. It is
# served by the frontend from its own image, built from this same content package
# -- see frontend/Dockerfile, which copies the file the SPA is served from. It is
# deliberately not duplicated into spa_config here: the backend does not serve it,
# and a second copy would be a stale one.
RUN cp -R /openmrs_distro/distro/target/sdk-distro/web/openmrs_config /openmrs/distribution/openmrs_config
COPY content-packages/referenceapplication/configuration/backend_configuration/addresshierarchy/addressConfiguration.xml /openmrs/distribution/openmrs_config/addresshierarchy/addressConfiguration.xml
COPY content-packages/referenceapplication/configuration/backend_configuration/addresshierarchy/addresshierarchy.csv /openmrs/distribution/openmrs_config/addresshierarchy/addresshierarchy.csv
RUN cp -R /openmrs_distro/distro/target/sdk-distro/web/openmrs_modules /openmrs/distribution/openmrs_modules/
RUN cp -R /openmrs_distro/distro/target/sdk-distro/web/openmrs_owas /openmrs/distribution/openmrs_owas

# --- Initializer package guard ----------------------------------------------
# A module's <package> is not cosmetic. OpenMRS resolves a module's
# <require_module> entries by string-matching the required name against
# Module.getPackageName(), with no fallback to the module id, so a module that
# declares the right package under the wrong name is not started at all -- and it
# is not started silently either: the dependent module is simply skipped with
# "cannot be started because it requires the following module(s)", while the
# Initializer itself runs happily.
#
# That is exactly what happened here. Initializer 2.12.1-intuvance.1 was published
# under the Maven groupId io.github.intuvance and derived its <package> from those
# coordinates, so it claimed io.github.intuvance.initializer while its classes were
# and remain in org.openmrs.module.initializer. patientdocuments 1.1.0 requires
# org.openmrs.module.initializer 2.9.0 and therefore never started. Nothing in the
# build or in `docker compose up` failed.
#
# This asserts the invariant instead of trusting the coordinate, and fails the
# build rather than shipping an image with a module that will not start. The
# expected value is read from the omod's own <activator>, so the two cannot
# disagree: OpenMRS loads the activator by that class name, so if the declared
# package ever stopped matching the activator's package the module would fail to
# start even with no dependents at all.
#
# python3 rather than unzip: the openmrs-core images have no unzip, and this runs
# in the dev stage. The script also strips XML comments before reading the tags,
# because config.xml contains prose that mentions <activator> by name.
COPY deployment/verify-initializer-package.py /tmp/verify-initializer-package.py
RUN python3 /tmp/verify-initializer-package.py \
        /openmrs/distribution/openmrs_modules/initializer-*.omod

# Clean up after copying needed artifacts
RUN mvn $MVN_ARGS clean

### Run stage
# The runtime image carries the production OpenMRS platform. Keep this in step with
# openmrs.version in distro/pom.xml.
FROM openmrs/openmrs-core:2.8.x-amazoncorretto-21

# Tomcat's HostConfig tries to create conf/Catalina/<hostname> on startup. This
# image runs as uid 1001 while /usr/local/tomcat/conf is root-owned, so the
# attempt fails and is logged SEVERE on every boot:
#
#   Unable to create directory for deployment: [/usr/local/tomcat/conf/Catalina/localhost]
#
# It is harmless for a single-host WAR deployment, but it is logged at SEVERE,
# which trains you to ignore SEVERE and so hides real ones. Pre-creating the
# directory with the runtime owner silences it without patching upstream.
#
# The base image sets USER 1001, so the ownership change has to be done as root
# and the runtime user restored afterwards, or the rest of the build would run
# unprivileged.
USER root
RUN mkdir -p /usr/local/tomcat/conf/Catalina/localhost \
 && chown -R 1001:0 /usr/local/tomcat/conf

# Tomcat rejects an oversized request body itself: the connector's maxPostSize
# defaults to 2 MB and answers 413 (or truncates the multipart body) long before
# the application ever sees the file. That is what makes a patient attachment
# upload fail with "413 Request Entity Too Large" on
# /openmrs/ws/rest/v1/attachment even when the gateway in front of it allows
# far more, so the gateway's limit alone is not enough -- the smaller of the two
# wins.
#
# 25 MB, matching the gateway's OMRS_MAX_UPLOAD_SIZE default. maxSwallowSize=-1
# makes Tomcat read the whole rejected body before closing the connection, so an
# over-limit upload fails with a clean 413 instead of a connection reset that the
# browser reports as a network error with no explanation.
#
# Only the live 8080 connector is patched. server.xml also carries several
# identical connector blocks inside XML comments as documentation; rewriting
# those would be harmless but would break the comment as an example. The awk
# script therefore tracks comment state and only edits outside comments.
# The awk program is carried in a quoted heredoc rather than as a backslash-
# continued RUN argument. The single-quoted awk program contains lines that must
# not be joined and must not be expanded by the shell, and a plain multi-line RUN
# is not valid Dockerfile at all -- the parser reads the second line of the awk
# program as a new instruction and fails with "unknown instruction: /<!--/".
RUN <<'TOMCAT_XML'
set -eu
awk '
    /<!--/  { incomment = 1 }
    !incomment && /<Connector port="8080"/ && !patched {
        print
        print "               maxPostSize=\"26214400\""
        print "               maxSwallowSize=\"-1\""
        patched = 1
        next
    }
    { print }
    /-->/ { incomment = 0 }
  ' /usr/local/tomcat/conf/server.xml > /usr/local/tomcat/conf/server.xml.new
grep -q maxPostSize /usr/local/tomcat/conf/server.xml.new
mv /usr/local/tomcat/conf/server.xml.new /usr/local/tomcat/conf/server.xml
chown 1001:0 /usr/local/tomcat/conf/server.xml
TOMCAT_XML
USER 1001

COPY --from=dev /openmrs/distribution/openmrs_core/openmrs.war /openmrs/distribution/openmrs_core/
COPY --from=dev /openmrs/distribution/openmrs-distro.properties /openmrs/distribution/
COPY --from=dev /openmrs/distribution/openmrs_modules /openmrs/distribution/openmrs_modules
COPY --from=dev /openmrs/distribution/openmrs_owas /openmrs/distribution/openmrs_owas
COPY --from=dev /openmrs/distribution/openmrs_config /openmrs/distribution/openmrs_config
