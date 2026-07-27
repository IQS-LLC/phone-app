"""
Beckhoff CX network discovery — finds live ADS targets on configured subnets.

Networking reality (read before assuming this "just works" everywhere)
------------------------------------------------------------------------
TwinCAT's own "Add Route" wizard discovers PLCs via a UDP broadcast on port
48899 — broadcasts are link-local by definition and do NOT cross routed
subnets (a router will not forward them) regardless of firewall rules. So
if every apartment's CX sits on its own subnet (e.g. 192.168.5.x per
apartment) and the Django server lives on a different subnet
(e.g. 192.168.10.x), broadcast discovery will only ever find devices on
whichever single subnet the server happens to be plugged into — it cannot
be made to "discover" devices across a router.

What DOES work across routed subnets, given IP routing is configured
between the server and the apartment subnets (a one-time network setup
task, not a software one):
  - A direct TCP scan of the ADS router port (48898) across a configured
    CIDR range. Routable, firewall-permitting, no broadcast involved.
  - Once a host responds on 48898, a real ADS connection (pyads) to read
    device info/state — this also routes normally over IP.

So this module implements a *configured-range TCP scan*, not broadcast
discovery. PLC_DISCOVERY_SUBNETS (env var, comma-separated CIDRs, e.g.
"192.168.5.0/24,192.168.6.0/24") must list every subnet an apartment CX
could be on; nothing is scanned until this is set, to avoid silently
sweeping unintended ranges. If a CX is on a subnet the server cannot route
to at all (no gateway between them), no software fix exists for that —
it's a network design problem to solve with the installer (routing,
VLANs, or a relay), and manual registration via /manage/devices/ remains
the production-safe fallback when discovery genuinely cannot reach a host.
"""
from __future__ import annotations

import ipaddress
import logging
import os
import socket
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

logger = logging.getLogger("lumina.discovery")

ADS_ROUTER_PORT = 48898
_MAX_HOSTS_PER_SCAN = 1024  # refuse to accidentally sweep something huge


def configured_subnets() -> list[str]:
    raw = os.getenv("PLC_DISCOVERY_SUBNETS", "")
    return [s.strip() for s in raw.split(",") if s.strip()]


def _hosts_in(cidr: str):
    net = ipaddress.ip_network(cidr, strict=False)
    return list(net.hosts())


def _probe_tcp(ip: str, port: int = ADS_ROUTER_PORT, timeout: float = 0.3) -> dict | None:
    t0 = time.monotonic()
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return {"ip": ip, "latency_ms": round((time.monotonic() - t0) * 1000, 1)}
    except OSError:
        return None


def _read_ads_info(ip: str, timeout: float = 1.0) -> dict:
    """
    Placeholder for a real ADS device-info read.

    This deliberately does NOT attempt to open an ADS connection: ADS
    requires the target's real AMS Net ID, which is never derivable from
    its IP (confirmed the hard way — see CLAUDE.md's AMS Net ID note and
    docs/plc_proposals/). Passing a bare IP as ams_net_id raises
    ValueError inside pyads every time, so the previous version of this
    function always silently fell back to "unreachable" even for a live
    PLC, without ever telling the caller why.

    A real fix means implementing Beckhoff's UDP broadcast discovery
    (port 48899) to learn the AmsNetId, or accepting TCP reachability as
    the extent of automatic discovery and having the installer enter the
    real AmsNetId manually (already the documented fallback — see
    /manage/devices/). Until one of those is built, this just reports
    "found on the network, identity unknown."
    """
    return {"ams_net_id": "", "device_name": "", "version": "", "ads_state": -1, "reachable_ads": False}


def scan(subnets: list[str] | None = None, mock: bool | None = None) -> list[dict[str, Any]]:
    """
    Scan configured (or explicitly given) CIDR ranges for live ADS routers.

    Returns a list of dicts: ip, latency_ms, ams_net_id, device_name,
    version, ads_state, reachable_ads.

    mock=True (or PLC_MOCK=True in env, the same flag the rest of the app
    uses) returns a fixed, realistic sample set instead of touching the
    network at all — discovery is exercised in demo/dev without any real
    PLCs present.
    """
    if mock is None:
        mock = os.getenv("PLC_MOCK", "True").lower() == "true"

    if mock:
        return _MOCK_RESULTS

    subnets = subnets if subnets is not None else configured_subnets()
    if not subnets:
        logger.warning("scan(): PLC_DISCOVERY_SUBNETS is not configured — nothing to scan")
        return []

    hosts: list[str] = []
    for cidr in subnets:
        try:
            hosts.extend(str(h) for h in _hosts_in(cidr))
        except ValueError as exc:
            logger.error("scan(): invalid CIDR %r: %s", cidr, exc)

    if len(hosts) > _MAX_HOSTS_PER_SCAN:
        logger.warning(
            "scan(): %d hosts requested, capping at %d — narrow PLC_DISCOVERY_SUBNETS",
            len(hosts), _MAX_HOSTS_PER_SCAN,
        )
        hosts = hosts[:_MAX_HOSTS_PER_SCAN]

    results: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=64) as pool:
        futures = {pool.submit(_probe_tcp, ip): ip for ip in hosts}
        open_hosts = []
        for fut in as_completed(futures):
            hit = fut.result()
            if hit is not None:
                open_hosts.append(hit)

        ads_futures = {pool.submit(_read_ads_info, h["ip"]): h for h in open_hosts}
        for fut in as_completed(ads_futures):
            host = ads_futures[fut]
            ads_info = fut.result()
            results.append({**host, **ads_info})

    results.sort(key=lambda r: tuple(int(p) for p in r["ip"].split(".")))
    return results


_MOCK_RESULTS = [
    {
        "ip": "192.168.5.10", "latency_ms": 1.2, "ams_net_id": "192.168.5.10.1.1",
        "device_name": "CX-Apartment16", "version": "3.1.4024", "ads_state": 5,
        "reachable_ads": True,
    },
    {
        "ip": "192.168.5.11", "latency_ms": 1.8, "ams_net_id": "192.168.5.11.1.1",
        "device_name": "CX-Apartment8", "version": "3.1.4024", "ads_state": 5,
        "reachable_ads": True,
    },
    {
        "ip": "192.168.5.12", "latency_ms": None, "ams_net_id": "", "device_name": "",
        "version": "", "ads_state": -1, "reachable_ads": False,
    },
]
