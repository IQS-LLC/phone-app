from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from .PLCLight import PLCLight
import threading
import logging
import os

logger = logging.getLogger(__name__)

FADE_MAP = {
    '0ms':    0,
    '500ms':  500,
    '1000ms': 1000,
    '2000ms': 2000,
    '5000ms': 5000,
}
DEFAULT_FADE = 2000


class PLCManager:
    _instance = None
    _lock = threading.Lock()

    def __init__(self):
        plc_netid = os.getenv('PLC_NETID', '5.168.214.75.1.1')
        plc_ip = os.getenv('PLC_IP', '192.168.0.161')
        # Default to mock=True — only use real PLC if explicitly enabled
        use_mock = os.getenv('PLC_MOCK', 'True').lower() == 'true'
        self.plc = PLCLight(plc_netid, plc_ip, mock=use_mock)
        self.connected = False

    def connect(self):
        try:
            self.plc.connect()
            self.connected = True
            logger.info("PLC connected (mock=%s)", self.plc.mock)
        except Exception as e:
            self.connected = False
            logger.error(f"PLC connection failed: {e}, switching to mock")
            self.plc.mock = True
            self.plc.connect()
            self.connected = True

    def get(self):
        if not self.connected:
            self.connect()
        return self.plc

    @classmethod
    def instance(cls):
        with cls._lock:
            if cls._instance is None:
                cls._instance = PLCManager()
            return cls._instance


def health(request):
    return JsonResponse({'status': 'ok'})


@csrf_exempt
def set_brightness(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=405)
    try:
        percent = int(request.POST.get('brightness', 0))
        percent = max(0, min(100, percent))
        plc = PLCManager.instance().get()
        plc.set_brightness(percent)
        return JsonResponse({'status': 'ok', 'brightness': percent})
    except Exception as e:
        logger.exception("Brightness error")
        return JsonResponse({'error': str(e)}, status=500)


@csrf_exempt
def set_fade(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=405)
    try:
        fade_str = request.POST.get('fade', '2000ms')
        fade_ms = FADE_MAP.get(fade_str, DEFAULT_FADE)
        plc = PLCManager.instance().get()
        plc.set_fade_time(fade_ms)
        return JsonResponse({'status': 'ok', 'fade': fade_str, 'fade_ms': fade_ms})
    except Exception as e:
        logger.exception("Fade error")
        return JsonResponse({'error': str(e)}, status=500)


def get_state(request):
    try:
        plc = PLCManager.instance().get()
        state = plc.read_state()
        return JsonResponse(state)
    except Exception as e:
        logger.exception("State read error")
        return JsonResponse({'error': str(e)}, status=500)


@csrf_exempt
def force_init(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=405)
    try:
        percent = int(request.POST.get('brightness', 50))
        percent = max(1, min(100, percent))
        plc = PLCManager.instance().get()
        plc.force_initialize(percent)
        return JsonResponse({'status': 'ok', 'initialized': True, 'brightness': percent})
    except Exception as e:
        logger.exception("Force init error")
        return JsonResponse({'error': str(e)}, status=500)