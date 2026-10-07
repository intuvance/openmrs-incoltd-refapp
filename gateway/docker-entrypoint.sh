#!/bin/sh
set -e

# Derive CERT_WEB_DOMAIN_COMMON_NAME from first domain in CERT_WEB_DOMAINS if not explicitly set
if [ -z "${CERT_WEB_DOMAIN_COMMON_NAME}" ] && [ -n "${CERT_WEB_DOMAINS}" ]; then
    CERT_WEB_DOMAIN_COMMON_NAME=$(echo "${CERT_WEB_DOMAINS}" | cut -d',' -f1)
    export CERT_WEB_DOMAIN_COMMON_NAME
fi

# Wait for the certificate before nginx reads its configuration.
#
# The SSL vhost references /etc/letsencrypt/live/<domain>/fullchain.pem, and nginx
# exits immediately if that file is absent. The certificate is issued by the
# separate certbot container, which is neither ordered before this one nor
# guaranteed to finish first: in dev mode it generates 2048-bit DH parameters
# before signing anything and then exits, so it is still working roughly two
# minutes after this container starts, and in prod mode it is a full ACME round
# trip. Without this wait nginx crash-loops for the whole of that.
#
# Waiting here rather than on a compose `depends_on` is deliberate. A healthcheck
# gate on certbot works right up until certbot exits -- which it does immediately
# in dev mode -- at which point the condition can never be satisfied again and the
# gateway is left in "Created" rather than started. Polling the file that is
# actually needed is correct in both modes regardless of whether certbot is still
# running, has finished, or never restarts.
#
# Bounded so a broken certbot surfaces as a clear message instead of a container
# that waits forever.
if [ -n "${CERT_WEB_DOMAIN_COMMON_NAME}" ]; then
    CERT_DIR="/etc/letsencrypt/live/${CERT_WEB_DOMAIN_COMMON_NAME}"
    CERT_WAIT_SECONDS="${CERT_WAIT_SECONDS:-600}"
    waited=0
    while [ ! -s "${CERT_DIR}/fullchain.pem" ] || [ ! -s "${CERT_DIR}/privkey.pem" ]; do
        if [ "${waited}" -ge "${CERT_WAIT_SECONDS}" ]; then
            echo "gateway: no certificate at ${CERT_DIR} after ${CERT_WAIT_SECONDS}s." >&2
            echo "gateway: check 'docker compose logs certbot'. With SSL_MODE=dev it" >&2
            echo "gateway: issues a self-signed certificate and exits 0; in prod mode it" >&2
            echo "gateway: needs CERT_WEB_DOMAINS and CERT_CONTACT_EMAIL, and ports 80/443." >&2
            exit 1
        fi
        if [ "${waited}" -eq 0 ]; then
            echo "gateway: waiting for the certificate at ${CERT_DIR} ..."
        fi
        sleep 3
        waited=$((waited + 3))
    done
    echo "gateway: certificate found after ${waited}s"
fi

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
