# Operations & Maintenance

## Updating the backend

Push to `main` → CI builds and (if `DEPLOY_ENABLED=true`) auto-deploys.

**Manual update without CI:**
```bash
docker pull <DOCKERHUB_USERNAME>/lugh-django:latest
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml up -d --no-deps django
```

## Rollback

```bash
docker images <DOCKERHUB_USERNAME>/lugh-django
# Pin a specific SHA tag in docker-compose.prod.yml:
#   image: <DOCKERHUB_USERNAME>/lugh-django:sha-<COMMIT_SHA>
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml up -d --no-deps django
```

## Database backup

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
docker exec lugh_db pg_dump -U lugh_user -d lugh_db --format=custom \
  > /volume1/docker/lugh/backups/lugh_db_${TIMESTAMP}.dump
```

A Celery Beat task already does this nightly (see `docs/deployment.md`) —
this is for a manual backup right before a risky change. To automate it
outside Celery too (e.g. via Synology Task Scheduler), the equivalent
`backup.sh` just wraps the same `pg_dump` command with retention pruning.

## Database restore (⚠️ destructive — overwrites the live database)

```bash
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml stop django celery-worker celery-beat
docker exec -i lugh_db pg_restore -U lugh_user -d lugh_db --clean --if-exists \
  < /volume1/docker/lugh/backups/lugh_db_<timestamp>.dump
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml start django celery-worker celery-beat
```

## Viewing logs

```bash
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml logs -f   # all
docker logs lugh_django --tail=100 -f                                     # one container
docker logs lugh_django 2>&1 | grep -E "ERROR|CRITICAL"                   # errors only
```

## Changing the server's IP

1. Change the IP (DSM Network Interface, or router DHCP reservation).
2. `.env`: `EXTRA_ALLOWED_HOSTS=<NEW_IP>,<existing tunnel hostnames>`.
3. `docker compose restart django`.
4. Update the ADS route on the CX (remove the old `<IP>.1.1` route, add the
   new one — see `docs/plc-integration.md`).

## Changing the PLC's IP

1. Change it on the CX in TwinCAT System Manager.
2. `.env`: `PLC_IP=<NEW_IP>`, `PLC_NETID=<NEW_IP>.1.1`.
3. `docker compose restart django celery-worker`.
4. App → Settings → Controllers → edit → Test Connection.
5. Re-verify the ADS route back to the server still exists (the route is
   from the PLC's perspective and isn't affected by the PLC's own IP
   changing, but confirming it's still there is good practice).

## Changing / rotating tunnel URLs

Any given tunnel's URL is not meant to be permanent (quick tunnels rotate on
every restart; even a named tunnel's domain can change if you move
registrars). Because the app already treats `LUGH_SERVER_URL` as a pool
(see `docs/architecture.md`), losing *one* tunnel in a multi-tunnel setup is
not an emergency — the app fails over automatically and you can replace that
one entry at your own pace. Losing *all* of them at once is the only
scenario that needs immediate action:

1. Stand up fresh tunnel(s) (`docs/deployment.md`'s Network & Internet
   Access section).
2. `.env`: add every new hostname to `EXTRA_ALLOWED_HOSTS`, restart
   `django`.
3. Update the GitHub secret with the full new comma-separated list:
   ```bash
   gh secret set LUGH_SERVER_URL --body "https://<url-1>,https://<url-2>" --repo <GITHUB_REPO>
   ```
4. Trigger a new CI build (push any commit to `main`) and redistribute the
   resulting APK/IPA — **already-installed apps cannot be redirected
   without a reinstall**, since the pool is baked in at build time. The one
   exception is the emergency "Advanced (Tech Team)" recovery sheet in the
   app itself, which can point a single already-installed device at one new
   URL without a rebuild, at the cost of collapsing that device's pool down
   to just that one URL.

## Replacing a Beckhoff CX PLC

1. Install TwinCAT 3 + the PLC program on the new CX, set it to RUN.
2. Same IP as the old CX: no backend changes needed. New IP: follow
   "Changing the PLC's IP" above.
3. Add an ADS route on the new CX pointing to the server
   (`docs/plc-integration.md`).
4. Verify the connection the same way.

## Replacing the server

1. Set up the new server following `docs/deployment.md` completely.
2. Same IP as the old one: simplest. New IP: follow "Changing the server's
   IP" above.
3. Restore the database from backup (above).
4. Copy Docker volumes from the old server:
   ```bash
   tar czf /tmp/lugh_data.tar.gz /volume1/docker/lugh/
   # transfer to new server, then:
   tar xzf lugh_data.tar.gz -C /
   ```
5. If using a named Cloudflare tunnel bound to the old server's IP:
   `cloudflared tunnel route ip add <NEW_IP>/32 lugh`.

## Rotating the database password

```bash
docker exec lugh_db psql -U lugh_user -d lugh_db -c \
  "ALTER USER lugh_user WITH PASSWORD '<NEW_PASSWORD>';"
# .env: set POSTGRES_PASSWORD and DB_PASSWORD to the same new value
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django
gh secret set DB_PASSWORD --body "<NEW_PASSWORD>" --repo <GITHUB_REPO>
```

## Tenant changeover (replacing a resident)

1. Settings → User Management → find the departing resident → **Disable**
   (not delete — preserves audit history).
2. Commissioning Wizard → Step 8 → add the new resident.
3. Hand over their login credentials.
