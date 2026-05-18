"""
PLC REST API views.

Endpoints:
  GET  /plc/                       health check
  GET  /plc/state/                 full system state (all channels)
  GET  /plc/devices/               device metadata (names, rooms)
  POST /plc/dali/<ch>/brightness/  set one DALI channel (1-16)
  POST /plc/dali/all/brightness/   set all DALI channels at once
  POST /plc/relay/<ch>/            set one wall relay (1-4)

All POST bodies are application/x-www-form-urlencoded.
All responses are JSON.
"""
import logging

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST

from .plc.registry import DeviceRegistry

logger = logging.getLogger(__name__)


def _registry() -> DeviceRegistry:
    return DeviceRegistry.instance()


# ── Health ────────────────────────────────────────────────────────────────────

def health(request):
    r = _registry()
    return JsonResponse({
        'status':    'ok',
        'mock':      r.mock,
        'connected': r.connected,
    })


# ── Full system state ─────────────────────────────────────────────────────────

@require_GET
def get_state(request):
    try:
        return JsonResponse(_registry().read_full_state())
    except Exception as exc:
        logger.exception("get_state error")
        return JsonResponse({'error': str(exc)}, status=500)


# ── Device metadata (names / rooms) ──────────────────────────────────────────

@require_GET
def get_devices(request):
    r = _registry()
    return JsonResponse({
        'dali':    [d.to_dict() for d in r.all_dali()],
        'relays':  [d.to_dict() for d in r.all_relays()],
        'switches': [s.to_dict() for s in r.all_switches()],
        'rooms':   r.rooms(),
    })


# ── DALI brightness — single channel ─────────────────────────────────────────

@csrf_exempt
@require_POST
def set_dali_brightness(request, channel: int):
    try:
        pct = int(request.POST.get('brightness', 0))
        pct = max(0, min(100, pct))
    except (TypeError, ValueError):
        return JsonResponse({'error': 'brightness must be 0-100'}, status=400)

    dev = _registry().dali(channel)
    if dev is None:
        return JsonResponse({'error': f'DALI channel {channel} not found'}, status=404)

    try:
        dev.set_brightness(pct)
        return JsonResponse({'status': 'ok', 'channel': channel, 'brightness': pct})
    except Exception as exc:
        logger.exception("set_dali_brightness ch%d error", channel)
        return JsonResponse({'error': str(exc)}, status=500)


# ── DALI brightness — all channels at once ───────────────────────────────────

@csrf_exempt
@require_POST
def set_dali_brightness_all(request):
    try:
        pct = int(request.POST.get('brightness', 0))
        pct = max(0, min(100, pct))
    except (TypeError, ValueError):
        return JsonResponse({'error': 'brightness must be 0-100'}, status=400)

    r = _registry()
    errors = []
    for dev in r.all_dali():
        try:
            dev.set_brightness(pct)
        except Exception as exc:
            errors.append(f'ch{dev.channel}: {exc}')
            logger.error("set_all_brightness ch%d: %s", dev.channel, exc)

    if errors:
        return JsonResponse({'status': 'partial', 'errors': errors}, status=207)
    return JsonResponse({'status': 'ok', 'brightness': pct})


# ── Wall relay ────────────────────────────────────────────────────────────────

@csrf_exempt
@require_POST
def set_relay(request, channel: int):
    raw = request.POST.get('state', '').lower()
    if raw not in ('true', 'false', '1', '0', 'on', 'off'):
        return JsonResponse(
            {'error': "state must be 'true'/'false'/'on'/'off'/'1'/'0'"}, status=400
        )
    on = raw in ('true', '1', 'on')

    dev = _registry().relay(channel)
    if dev is None:
        return JsonResponse({'error': f'Relay channel {channel} not found'}, status=404)

    try:
        dev.set_state(on)
        return JsonResponse({'status': 'ok', 'channel': channel, 'on': on})
    except Exception as exc:
        logger.exception("set_relay ch%d error", channel)
        return JsonResponse({'error': str(exc)}, status=500)
