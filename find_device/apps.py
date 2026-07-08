import logging

from django.apps import AppConfig

logger = logging.getLogger(__name__)


class FindDeviceConfig(AppConfig):
    name = 'find_device'

    def ready(self):
        # DeviceRegistry instances are created lazily, per apartment, on
        # first request (see DeviceRegistry.for_apartment) — with hundreds
        # of apartments possible, eagerly connecting to every PLC at Django
        # startup doesn't scale and isn't attempted here.
        logger.info("FindDeviceConfig: ready (PLC connections are lazy, per-apartment)")
