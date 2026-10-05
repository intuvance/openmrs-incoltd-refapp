# SSL / HTTPS configuration

Upstream guide, retained from the OpenMRS reference application distribution. It
still applies: `docker-compose.ssl.yml` is unchanged by the site configuration
layer.

## Requirements for production

The stack terminates TLS at the gateway (nginx). Everything else, including the
backend, stays on the internal compose network and is never published to the host.
Only the gateway publishes a port.

In production you must also set `OMRS_REST_PROXY` to the public `https://` URL.
Without it OpenMRS generates `http://` links in outbound content such as
password-reset mail and appointment reminders, which a browser will then treat as
mixed content and block.

## SSL/HTTPS Configuration

The application can be run with SSL/HTTPS support for both development and production environments.

SSL configuration lives in `docker-compose.ssl.yml`, which is included alongside the base `docker-compose.yml`. The recommended way to enable it is via a `.env` file in the project root:

```env
COMPOSE_FILE=docker-compose.yml:docker-compose.ssl.yml
```

This tells Docker Compose to automatically include the SSL overlay, so all commands remain simply `docker compose up`, `docker compose down`, etc. without needing `-f` flags. All SSL-related environment variables (like `SSL_MODE` and `CERT_WEB_DOMAINS`) can also be set in this file.

### Development mode (self-signed certificates)

For local development with HTTPS:

```env
# .env
COMPOSE_FILE=docker-compose.yml:docker-compose.ssl.yml
```

```bash
docker compose up
```

This will:
- Automatically generate self-signed certificates for `localhost` and `127.0.0.1`
- Configure nginx to use HTTPS on port 443
- Redirect HTTP (port 80) to HTTPS

The application will be accessible at:
- https://localhost/openmrs/spa
- https://127.0.0.1/openmrs/spa

**Note**: Your browser will show a security warning for self-signed certificates. This is expected - click "Advanced" and proceed to the site.

### Production mode (Let's Encrypt)

For production deployments with valid SSL certificates from Let's Encrypt, create a `.env` file:

```env
# .env
COMPOSE_FILE=docker-compose.yml:docker-compose.ssl.yml
SSL_MODE=prod
CERT_WEB_DOMAINS=example.com
CERT_CONTACT_EMAIL=admin@example.com
```

```bash
docker compose up
```

**Configuration options**:

- `SSL_MODE=prod` - Use Let's Encrypt certificates (required)
- `CERT_WEB_DOMAINS` - Your domain name(s), comma-separated (e.g., `example.com,www.example.com`). The first domain is used as the primary domain for certificate paths and the nginx `server_name` directive.
- `CERT_CONTACT_EMAIL` - Email for Let's Encrypt notifications
- `CERT_WEB_DOMAIN_COMMON_NAME` - (Optional) Override the primary domain. By default, this is derived from the first domain in `CERT_WEB_DOMAINS`. You only need to set this if you want the certificate's common name to differ from the first domain.
- `SSL_STAGING=true` - (Optional) Use Let's Encrypt staging environment for testing

**The certbot container will**:
1. Create a temporary certificate to allow nginx to start
2. Wait for nginx to be ready
3. Request a real Let's Encrypt certificate via ACME HTTP-01 challenge
4. Reload nginx with the real certificate
5. Run a renewal daemon that checks for renewal every 12 hours

**Important**: Ensure your domain's DNS is correctly configured to point to your server before starting, as Let's Encrypt needs to verify domain ownership via HTTP.

### Testing with Let's Encrypt staging

To test the SSL setup without hitting Let's Encrypt rate limits, add `SSL_STAGING=true` to your `.env` file:

```env
# .env
COMPOSE_FILE=docker-compose.yml:docker-compose.ssl.yml
SSL_MODE=prod
SSL_STAGING=true
CERT_WEB_DOMAINS=example.com
CERT_CONTACT_EMAIL=admin@example.com
```

Staging certificates won't be trusted by browsers but allow you to verify the setup works correctly. Remove `SSL_STAGING` (or set it to `false`) once you've confirmed the setup works.

### Certificate profiles

Let's Encrypt offers different certificate profiles with varying validity periods:

| Profile | Validity | Use Case |
|---------|----------|----------|
| `classic` | 90 days (default) | Standard certificates |
| `tlsserver` | 45 days | Shorter validity for improved security |
| `shortlived` | 6 days | Required for IP address certificates |

To request a specific profile, add `CERT_PROFILE` to your `.env` file:

```env
# .env (additions)
CERT_PROFILE=tlsserver
```

**Note**: Let's Encrypt is transitioning all certificates to 45-day validity by 2028. Using the `tlsserver` profile allows you to opt-in to shorter certificates now.

### IP address certificates

Let's Encrypt now supports issuing certificates for publicly-addressable IP addresses. These certificates must use the `shortlived` profile (6-day validity).

```env
# .env
COMPOSE_FILE=docker-compose.yml:docker-compose.ssl.yml
SSL_MODE=prod
CERT_WEB_DOMAINS=203.0.113.50
CERT_CONTACT_EMAIL=admin@example.com
```

**Important notes for IP address certificates**:
- The IP address must be publicly addressable (not private IPs like 192.168.x.x or 10.x.x.x)
- The `shortlived` profile is automatically selected when an IP address is detected
- Certificates are valid for approximately 6 days and renew automatically
- IPv6 addresses are also supported

You can also mix domain names and IP addresses:

```env
CERT_WEB_DOMAINS=example.com,203.0.113.50
```

When any IP address is included, the shortlived profile is required and will be automatically enforced.

### Manual certificate renewal

While certificates renew automatically in production mode, you can manually force renewal if needed.

**If the certbot container is running** (prod mode):

```bash
# Force renewal
docker compose exec certbot certbot renew --force-renewal --webroot -w /var/www/certbot

# Reload nginx to pick up new certificates
docker compose exec gateway nginx -s reload
```

**If certbot container has stopped or for one-off renewal**:

```bash
# Run certbot in one-off mode (override entrypoint to run certbot directly)
docker compose run --rm --entrypoint certbot certbot \
  renew --force-renewal --webroot -w /var/www/certbot

# Reload nginx
docker compose exec gateway nginx -s reload
```

**Check certificate expiration**:

```bash
# If certbot container is running
docker compose exec certbot certbot certificates

# If certbot container is stopped
docker compose run --rm --entrypoint certbot certbot certificates
```

### Regenerating certificates

If you need to start fresh with certificates (e.g., after changing domains), delete the letsencrypt volume and restart:

```bash
docker compose down

# Remove only this project's letsencrypt volume
docker volume rm "$(docker compose config | awk '/^name:/{print $2}')_letsencrypt-data"

docker compose up
```

The certbot entrypoint skips certificate generation when it finds existing certificates for the configured domain. Removing the volume forces it to go through the full setup process again.

### Running with Grafana

The service can run with Grafana for monitoring logs. You can run it with:
```bash
docker compose -f docker-compose.yml -f docker-compose.grafana.yml up
```
Grafana will be available at http://localhost/grafana. Use admin as username and see docker-compose.grafana.yml for the initial password.

If you would like to use grafana in your distro, you just need to copy over `docker-compose.grafana.yml`.
