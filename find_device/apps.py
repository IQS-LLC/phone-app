import logging
import os

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
        self._set_local_ams_address()

    def _set_local_ams_address(self):
        """
        Set this host's own AMS Net ID once at process startup, before any
        ADS connection is opened.

        Without this, pyads' Linux route-less router defaults to an
        unroutable '0.0.0.0.1.1' local identity. The target CX's ADS route
        table is keyed on this AMS Net ID (not on the TCP source IP), so
        every real connection times out or fails route validation until
        this matches whatever identity was registered on the CX (via
        TwinCAT System Manager or ADSClient.add_route).
        """
        if os.getenv('PLC_MOCK', 'True').lower() == 'true':
            return
        local_net_id = os.getenv('LOCAL_AMS_NET_ID')
        if not local_net_id:
            logger.warning(
                "FindDeviceConfig: LOCAL_AMS_NET_ID not set — real ADS "
                "connections will likely fail route validation on the "
                "target PLC. Set it to this host's AMS Net ID (the one "
                "the CX has a route for)."
            )
            return
        try:
            import pyads
            pyads.open_port()
            pyads.set_local_address(local_net_id)
            logger.info("FindDeviceConfig: local AMS Net ID set to %s", local_net_id)
        except Exception as exc:
            logger.error("FindDeviceConfig: failed to set local AMS Net ID: %s", exc)
