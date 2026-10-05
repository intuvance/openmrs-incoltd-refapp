# syntax=docker/dockerfile:1.3
#--------------------------------------------
# Dev Stage - Assembles and Builds Frontend
#--------------------------------------------
FROM --platform=$BUILDPLATFORM node:22-alpine as dev

# The build context is the repository root, not this directory, because the SPA
# config shipped below lives in the content package rather than in frontend/. Every
# COPY source is therefore root-relative. Keep this in step with the `frontend`
# service's `build.context` in docker-compose.override.yml.
ARG APP_SHELL_VERSION=10.0.0

RUN mkdir -p /app
WORKDIR /app

COPY frontend/spa-assemble-config.json .
COPY frontend/spa-build-config.json .

ARG CACHE_BUST
RUN npx --legacy-peer-deps openmrs@${APP_SHELL_VERSION:-10.0.0} assemble --manifest --mode config --config spa-assemble-config.json --target ./spa
RUN npx --legacy-peer-deps openmrs@${APP_SHELL_VERSION:-10.0.0} build --build-config spa-build-config.json --target ./spa
RUN if [ ! -f ./spa/index.html ]; then echo 'Build failed. Please check the logs above for details. This may have happened because of an update to a library that OpenMRS depends on.'; exit 1; fi

#--------------------------------------------
# Runtime Stage - Published Image
#--------------------------------------------
FROM nginx:1.31-alpine

RUN apk update && \
    apk upgrade && \
    # add more utils for sponge and envsubst
    apk add --no-cache moreutils

# clear any default files installed by nginx
RUN rm -rf /usr/share/nginx/html/*

COPY frontend/startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh

COPY frontend/nginx.conf /etc/nginx/nginx.conf

COPY --from=dev /app/spa /usr/share/nginx/html

# The SPA config the frontend serves at OMRS_SPA_CONFIG_URLS.
#
# This must be the SITE configuration, not a demo placeholder. The site
# configuration lives in the content package at
# content-packages/referenceapplication/configuration/frontend_configuration/config.json,
# and carries the queue concept UUIDs, logo and brand colours that make this
# deployment recognisable.
#
# The build context is the repository root (see docker-compose.override.yml) so
# that the file can be reached, and it is copied at build time rather than mounted
# so the config and the SPA shell are guaranteed to be the same revision -- the
# SPA fetches this file by URL at runtime, so a version mismatch fails silently in
# the UI.
#
# This is deliberately NOT delivered by the Initializer: it has no
# FRONTEND_CONFIGURATION domain, so nothing would ever write it.
COPY content-packages/referenceapplication/configuration/frontend_configuration/config.json /usr/share/nginx/html/config-core.json

CMD ["/usr/local/bin/startup.sh"]
