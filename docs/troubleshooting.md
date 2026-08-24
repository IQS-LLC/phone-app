# Troubleshooting

## Django container is unhealthy

**Symptoms:** `docker ps` shows `lugh_django` unhealthy; the app shows 502.

```bash
docker logs lugh_django --tail=50
```

| Log Message | Cause | Fix |
|---|---|---|
| `could not connect to server: Connection refused` | PostgreSQL not ready | Wait; check `lugh_db` health |
| `FATAL: password authentication failed` | `DB_PASSWORD` ≠ `POSTGRES_PASSWORD` | Fix `.env`, restart all |
| `RuntimeError: Refusing to start` | `SECRET_KEY` not set | Set `SECRET_KEY` in `.env` |
| `DisallowedHost` | The requesting hostname (server IP or a tunnel URL) isn't in `EXTRA_ALLOWED_HOSTS` | Add it, restart |
| `django.db.utils.ProgrammingError` | Migration failed | `docker exec lugh_django python manage.py migrate` |

## Nginx 502 Bad Gateway

Django is down, or its container IP changed underneath Nginx.

```bash
docker exec lugh_nginx nginx -s reload
# If that doesn't help:
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart nginx
```

## ADS connection fails

```bash
docker exec lugh_django nc -zv <PLC_IP> 48898
docker exec lugh_django nc -zv <PLC_IP> 851

docker exec lugh_django python manage.py shell -c "
import pyads
conn = pyads.Connection('<PLC_AMS_NET_ID>', pyads.PORT_TC3PLC1, '<PLC_IP>')
conn.open()
print(conn.read_state())
conn.close()
"
```

| Result | Cause | Fix |
|---|---|---|
| `nc` fails on 48898 | No network path or firewall | Check cables, switch, CX firewall |
| `nc` works, ADS fails | No route on the CX | Add ADS route (`docs/plc-integration.md`) |
| Route exists, ADS fails | Wrong AMS Net IDs | Verify `<PLC_AMS_NET_ID>` = `<PLC_IP>.1.1` |
| ADS works but state ≠ RUN | PLC not running | Set TwinCAT to RUN |

## App cannot connect to the backend

```bash
curl https://<one of the tunnel URLs>/health/
```

| Result | Cause | Fix |
|---|---|---|
| Connection refused on one URL, others fine | That specific tunnel is down | If you're running the recommended multi-tunnel pool, the app should already have failed over automatically — check Settings → System Status → Failover in the app to confirm. Fix or replace the dead tunnel at your own pace. |
| Connection refused on *every* URL | All tunnels down simultaneously (whatever hosts them is offline, or they were never made durable — see `docs/deployment.md`'s Option C warning about not running tunnels as ad-hoc terminal processes) | Restore connectivity per `docs/operations.md`'s "Changing / rotating tunnel URLs" (total-outage path) |
| 502 | Django down | See "Django container is unhealthy" above |
| `curl` works, app still fails | The app's baked-in URL pool doesn't include this URL at all | Rebuild with the correct `LUGH_SERVER_URL` |
| 401 on login | Wrong credentials | Verify in Django admin |
| CORS error | Tunnel hostname not in `EXTRA_ALLOWED_HOSTS` | Add it, restart Django |

## A quick tunnel's URL changed after a restart

This is expected behavior for quick tunnels (Option A in
`docs/deployment.md`), not a bug — they don't have a stable hostname. Find
the new URL from `cloudflared`'s own metrics endpoint:

```bash
curl http://localhost:2000/metrics | grep trycloudflare
```

If you're running a single tunnel, treat this exactly like the "all tunnels
down" case in `docs/operations.md` — replace the URL, update `.env` and the
GitHub secret, rebuild, redistribute. If you're running the recommended
multi-tunnel pool and only one entry rotated, the app already failed over to
a healthy one automatically; there's no urgency, just replace that one
pool entry when convenient.

## Celery tasks not running

```bash
docker logs lugh_celery_worker --tail=50
docker logs lugh_celery_beat --tail=50
docker exec lugh_celery_worker python -c "
import redis; r = redis.from_url('redis://redis:6379/0'); print(r.ping())
"
```

If the Redis ping fails: `docker restart lugh_redis`, then `docker restart
lugh_celery_worker lugh_celery_beat`.

## GitHub Actions deployment fails

| Job | Failure | Fix |
|---|---|---|
| Django Tests | `makemigrations --check` fails | `python manage.py makemigrations` → commit |
| Build Django Image | Docker Hub auth fails | Regenerate `DOCKERHUB_TOKEN` |
| Build Android APK | Keystore error | Re-encode: `base64 -w 0 lugh-release.jks` → update `ANDROID_KEYSTORE_B64` |
| Deploy | Runner offline | SSH to the server → `cd /volume1/docker/lugh/runner && ./svc.sh start` |
| Deploy | `docker pull` fails | Docker Hub rate limit — wait ~10 min, re-run |

## PLC symbols not found after discovery

```bash
docker exec lugh_django python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
client = ADSClient('<PLC_AMS_NET_ID>', '<PLC_IP>')
client.connect()
symbols = client.get_all_symbols()
print(f'Total symbols: {len(symbols)}')
for s in symbols[:20]:
    print(s['full_name'], '—', s['type_name'])
client.disconnect()
"
```

If zero symbols: the TwinCAT GVL isn't exposing anything at all, or ADS
access is blocked. See `docs/plc-integration.md` for the current expected
GVL layout to check against.
