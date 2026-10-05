# syntax=docker/dockerfile:1.3
FROM nginx:1.31-alpine

ENV FRAME_ANCESTORS=""

# Rendered to /etc/nginx/nginx.conf by docker-entrypoint.sh, which substitutes
# OMRS_MAX_UPLOAD_SIZE. Copied as a template rather than directly so the upload
# limit is configurable without rebuilding the image.
COPY nginx.conf /etc/nginx/nginx.conf.template
COPY default.conf.template /etc/nginx/conf-templates/
COPY default-ssl.conf.template /etc/nginx/conf-templates/
COPY docker-entrypoint.sh /usr/local/bin/
COPY watch-certs.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/watch-certs.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
