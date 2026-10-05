# Operations

Backup, restore, upgrade and incident procedures for the Intuvance OpenMRS O3
distribution.

---

## What holds what

| Volume | Mounted at | Contents | Loss impact |
|---|---|---|---|
| `db-data` | `db:/var/lib/mysql` | the entire clinical record, all metadata, all users | **catastrophic** |
| `openmrs-data` | `backend:/openmrs/data` | uploaded files (patient documents, attachments), the Initializer's `configuration_checksums`, OpenMRS logs | serious |
| `letsencrypt-data` | `gateway:/etc/letsencrypt` | TLS certificates | reissue |
| `certbot-data` | `gateway:/var/www/certbot` | ACME challenge files | transient |

Back up `db-data` and `openmrs-data`. The others are regenerable.

---

## Backup

### Database

Use `mariadb-dump` with `--single-transaction` so the dump is consistent without
locking tables:

```bash
mkdir -p backups
docker compose exec -T db mariadb-dump \
  -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  --single-transaction --routines --events --triggers \
  openmrs | gzip > "backups/openmrs-$(date +%F-%H%M).sql.gz"
```

Verify the archive is not empty before you rely on it:

```bash
gunzip -c "backups/openmrs-YYYY-MM-DD-HHMM.sql.gz" | tail -5
```

That must end with a completed dump footer, not a `Got error: ...` line.

### Uploaded files

```bash
docker run --rm \
  -v "$(docker volume ls -q -f name=_openmrs-data):/data:ro" \
  -v "$PWD/backups:/backup" \
  alpine tar czf "/backup/openmrs-data-$(date +%F).tar.gz" -C /data .
```

Confirm the volume name before running this; the suffix depends on the Compose
project name.

### Nightly cron

```cron
15 2 * * * cd /opt/openmrs-distro && ./backup.sh >> /var/log/openmrs-backup.log 2>&1
```

A backup you have not restored from is not a backup. Run a restore drill
quarterly.

---

## Restore

Into an **empty** volume:

```bash
docker compose down
docker volume rm "$(docker compose config | awk '/^name:/{print $2}')_db-data"
docker compose up -d db
until docker compose exec -T db healthcheck.sh --connect --innodb_initialized; do sleep 2; done

gunzip -c backups/openmrs-YYYY-MM-DD-HHMM.sql.gz \
  | docker compose exec -T db mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" openmrs

# The marker travels with the dump, so db-init will correctly skip seeding.
docker compose up -d
```

---

## Upgrading

### Routine (same OpenMRS release line)

```bash
git pull
docker compose build
docker compose up -d
tests/acceptance/startup-acceptance.sh upgrade
```

Existing volumes are reused. `db-init` sees the `db_initialised` marker and exits
immediately. Liquibase applies any module schema changes automatically.

Take a backup first. This is not optional.

### OpenMRS platform upgrade

A database from one platform line should not be pointed at a backend from another.
The seed image is version-matched for exactly this reason.

Preferred path — dump, move to a fresh volume, let the new backend upgrade it:

```bash
# 1. dump on the old line
docker compose exec -T db mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" \
  --single-transaction --routines --events openmrs > pre-upgrade.sql

# 2. build the new images and start against fresh volumes
docker compose down
docker volume rm "$(docker compose config | awk '/^name:/{print $2}')_db-data"
docker compose up -d db
until docker compose exec -T db healthcheck.sh --connect --innodb_initialized; do sleep 2; done
mariadb -h 127.0.0.1 -u root -p"$MYSQL_ROOT_PASSWORD" openmrs < pre-upgrade.sql

# 3. start the new backend; Liquibase upgrades the schema on boot
docker compose up -d
docker compose logs -f backend
```

Then reconcile the new release's seed image and site content package against the
upgrade, and re-run the acceptance test.

If the new platform's Liquibase changeset is not backward compatible, restore into
a fresh database and let the new line create the schema, then migrate clinical
data explicitly. Do not attempt to run the old backend against the new schema.

---

## Rotating database credentials

```bash
NEW=$(openssl rand -base64 32)

# Revoke the current password, then set the new one. Do it in one session so the
# backend is never left with credentials that match neither.
docker compose exec -T db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
  "ALTER USER 'openmrs'@'%' IDENTIFIED BY '${NEW}'; FLUSH PRIVILEGES;"

# Update .env, then restart only the backend.
sed -i "s/^OMRS_DB_PASSWORD=.*/OMRS_DB_PASSWORD=${NEW}/" .env
docker compose up -d backend
```

`db-init` will not re-run, so it will not revert the change. Verify:

```bash
docker compose exec -T backend \
  curl -fsS http://localhost:8080/openmrs/initialsetup
```

---

## First-run checklist

1. TLS is enabled and the certificate is valid (not staging).
2. `OMRS_REST_PROXY` is set to the public `https://` URL.
3. The default `admin` password has been changed.
4. No demo users exist:
   ```sql
   SELECT username FROM users WHERE username IN ('doctor','nurse','clerk','technician','daemon');
   ```
   Expect zero rows.
5. The Login Location tag exists, a location carries it, and `login.location`
   resolves to that location.
6. CIEL mappings are present:
   ```sql
   SELECT COUNT(*) FROM concept_reference_map;
   ```
7. `openconceptlab.subscriptionUrl` is unset.
8. Backups are scheduled and one has been restored from successfully.
9. All images are digest-pinned in `.env`.
10. `tests/acceptance/startup-acceptance.sh` passes.

---

## Incident triage

| Symptom | First check | Likely cause |
|---|---|---|
| backend not starting | `docker compose logs db-init` | seed or credential rotation failed; backend waits on it by design |
| `initialsetup` 503 | `docker compose logs backend \| grep -iE 'error\|fatal'` | datasource unreachable, or a module failed to load |
| no module in the UI | `SELECT module_id FROM openmrs_module WHERE load_error IS NOT NULL` | module dependency or version conflict |
| empty forms, empty order sets | `SELECT COUNT(*) FROM concept_reference_map` | terminology missing; the seed did not load |
| very slow startup | `docker compose logs backend \| grep -i searchindex` | search index rebuild; set `OMRS_CONFIG_SCHEDULER_STARTUP=false` |
| startup exception mentioning OCL | `ls` the OCL configuration domain | an archive was left where OCL scans at boot |
| gateway 502 | `docker compose logs gateway backend` | backend is up but not serving, or the route changed |

### Distinguishing failure classes

Log prefixes make the class visible without cross-reading:

```text
[db-init] ...                 database and initialisation
org.openmrs.module.*          module loading
openmrs.module.initializer    content package application
org.openmrs.module.openconceptlab   terminology
nginx                        frontend / routing
```

### Reinitialising a broken install

Only on a disposable environment. `db-init` is guarded and will not help here; a
corrupted volume has to be replaced, and that destroys the data:

```bash
docker compose down -v      # DESTROYS ALL DATA
```

Take a backup first, and prefer restore over reinitialisation.
