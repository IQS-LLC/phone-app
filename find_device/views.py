from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from .PLCLight import PLCLight
import threading
import logging

logger = logging.getLogger(__name__)


# ═══════════════════════════════════════════════════════════
#  FADE MAP
#  Flutter sends a string like '0ms', '500ms', etc.
#  We resolve it here to an integer ms value, then pass the
#  integer into PLCLight.set_fade_time() which maps it to
#  the correct Tc3_DALI E_DALIFadeTime enum index.
# ═══════════════════════════════════════════════════════════
FADE_MAP = {
    '0ms':    0,
    '500ms':  500,
    '1000ms': 1000,
    '2000ms': 2000,
    '5000ms': 5000,
}
DEFAULT_FADE = 2000


# ═══════════════════════════════════════════════════════════
#  THREAD-SAFE PLC MANAGER  (singleton)
# ═══════════════════════════════════════════════════════════
class PLCManager:
    _instance = None
    _lock     = threading.Lock()

    def __init__(self):
        self.plc       = PLCLight('5.168.214.75.1.1', '192.168.0.161', mock=False)
        self.connected = False

    def connect(self):
        try:
            self.plc.connect()
            self.connected = True
            logger.info("PLC connected")
        except Exception as e:
            self.connected = False
            logger.error(f"PLC connection failed: {e}")
            self.plc.mock = True
            self.plc.connect()
            self.connected = True
            logger.info("Mock PLC connected (fallback)")

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


# ═══════════════════════════════════════════════════════════
#  HEALTH CHECK
#  GET  /plc/health/
# ═══════════════════════════════════════════════════════════
def health(request):
    return JsonResponse({'status': 'ok'})


# ═══════════════════════════════════════════════════════════
#  SET BRIGHTNESS
#  POST  /plc/brightness/
#  Body: brightness=<0..100>
# ═══════════════════════════════════════════════════════════
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


# ═══════════════════════════════════════════════════════════
#  SET FADE
#  POST  /plc/fade/
#  Body: fade=<'0ms'|'500ms'|'1000ms'|'2000ms'|'5000ms'>
# ═══════════════════════════════════════════════════════════
@csrf_exempt
def set_fade(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=405)
    try:
        fade_str = request.POST.get('fade', '2000ms')
        fade_ms  = FADE_MAP.get(fade_str, DEFAULT_FADE)
        plc = PLCManager.instance().get()
        plc.set_fade_time(fade_ms)
        return JsonResponse({'status': 'ok', 'fade': fade_str, 'fade_ms': fade_ms})
    except Exception as e:
        logger.exception("Fade error")
        return JsonResponse({'error': str(e)}, status=500)


# ═══════════════════════════════════════════════════════════
#  GET STATE
#  GET  /plc/state/
#  Returns: { actual_percent, system_ready, light_error,
#             button1, button2 }
# ═══════════════════════════════════════════════════════════
def get_state(request):
    try:
        plc   = PLCManager.instance().get()
        state = plc.read_state()
        return JsonResponse(state)
    except Exception as e:
        logger.exception("State read error")
        return JsonResponse({'error': str(e)}, status=500)


# ═══════════════════════════════════════════════════════════
#  FORCE INITIALIZE
#  POST  /plc/init/
#  Body: brightness=<1..100>  (optional, default 50)
#
#  After a CX restart the DALI bus is cold and the app can't
#  control the lights until a physical button press generates
#  the rising edge on GVL.bLightOn that rtAppLight (R_TRIG)
#  needs to fire fbDirect.
#
#  This endpoint replicates that button press sequence
#  entirely from software:
#    1. Pre-load nDimLevel with the requested brightness
#    2. Pulse bLightOn FALSE → TRUE  (rising edge)
#    3. Fire _trigger() (bLightTrigger pulse) for POU_Control
#
#  Add to urls.py:  path('plc/init/', views.force_init)
# ═══════════════════════════════════════════════════════════
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