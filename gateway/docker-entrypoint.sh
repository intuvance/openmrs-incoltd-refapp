#!/bin/sh
set -e

# Create templates directory if it doesn't exist
mkdir -p /etc/nginx/templates

# Upload size limit, applied to nginx's own body limit (client_max_body_size in
# nginx.conf). nginx's default is 1m, which rejects patient attachments and other
# large uploads with 413 before they reach the backend, so the default here is
# deliberately generous. Keep it in step with the Tomcat connector limit patched
# in the backend image: the smaller of the two is the effective one.
OMRS_MAX_UPLOAD_SIZE="${OMRS_MAX_UPLOAD_SIZE:-25m}"

# Only OMRS_MAX_UPLOAD_SIZE is substituted. A bare `envsubst` would also expand
# nginx's own runtime variables ($remote_addr, $request, $host, ...), which must
# reach nginx verbatim.
envsubst '${OMRS_MAX_UPLOAD_SIZE}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Derive CERT_WEB_DOMAIN_COMMON_NAME from first domain in CERT_WEB_DOMAINS if not explicitly set
if [ -z "${CERT_WEB_DOMAIN_COMMON_NAME}" ] && [ -n "${CERT_WEB_DOMAINS}" ]; then
    CERT_WEB_DOMAIN_COMMON_NAME=$(echo "${CERT_WEB_DOMAINS}" | cut -d',' -f1)
    export CERT_WEB_DOMAIN_COMMON_NAME
fi

# Determine which nginx config to use based on SSL environment variable
if [ -n "${CERT_WEB_DOMAIN_COMMON_NAME}" ]; then
    echo "SSL enabled: Using SSL nginx configuration"
    cp /etc/nginx/conf-templates/default-ssl.conf.template /etc/nginx/templates/default.conf.template

    # Start certificate reload watcher in background
    echo "Starting certificate reload watcher..."
    /usr/local/bin/watch-certs.sh &
else
    echo "SSL disabled: Using standard nginx configuration"
    cp /etc/nginx/conf-templates/default.conf.template /etc/nginx/templates/default.conf.template
fi

# Execute the original nginx entrypoint
exec /docker-entrypoint.sh "$@"
