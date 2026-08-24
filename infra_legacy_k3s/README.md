# Legacy: k3s/Helm deployment path (superseded, not maintained)

**Status confirmed by the project owner on 2026-08-24: this entire directory
is dead scaffolding from an earlier deployment direction that was never
finished or used in production.** It's kept here for historical reference
only, not as a supported alternative deployment target.

**The real, current production deployment** is the NAS + Docker Compose +
Cloudflare Tunnel setup described in `CLAUDE.md` and
`docs/deployment.md`/`docs/DEPLOYMENT_MANUAL.md` — that's what's actually
running today and what any deployment work should target.

What's in here: a Helm chart (`helm/lugh/`) and bootstrap script
(`scripts/bootstrap-server.sh`) for running the stack on a k3s cluster at a
different host (`192.168.0.192`) than the current production NAS, plus
supporting Docker images (`docker/mock-plc/`, `docker/nginx/`) built for that
chart specifically — none of this is referenced by the current
`docker-compose.dev.yml`/`docker-compose.prod.yml`, which is what's actually
in use.

If a real need for Kubernetes/Helm deployment comes up again in the future,
treat this as a starting reference, not a finished or trustworthy artifact —
it predates the current architecture (multi-endpoint Cloudflare failover,
the current container names/topology, etc.) and would need a full review
before being relied on.
