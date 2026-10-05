# OpenMRS Gateway

The gateway service is a simple Nginx Docker container that routes requests either to the frontend or the backend as appropriate. Using a service like this enables us to largely ignore CORS issues since both the backend and frontend are served from the same origin.

The main configuration for the gateway can be found in the default.conf.template file. this file is processed at start-up by the NGinx Docker containers envsubst setup, which allows us to substitute  environment variables into the configuration.

## Supported Environment Variables

`FRAME_ANCESTORS`
: This should be a space separated list of origins that are allowed to embed OpenMRS in an IFRAME. For example "http://my.webpage/com http://my.webpage2.com". The syntax is described [on MDN](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Content-Security-Policy/frame-ancestors). By default, only pages served from the gateway can embed OpenMRS in an IFRAME.

`OMRS_MAX_UPLOAD_SIZE`
: Maximum size of a single request body, substituted into `client_max_body_size` in `nginx.conf`. Defaults to `25m`; nginx's own default is `1m`, which rejects patient attachments and other large uploads with 413 before they are proxied. `nginx.conf` is rendered from a template by `docker-entrypoint.sh`, because unlike `conf.d` it is not processed by the base image's envsubst setup. The effective limit is the smaller of this and the Tomcat connector's `maxPostSize` in the backend image, so raising this past 25 MB requires rebuilding the backend as well.
