# Django-side status for this proposal

Already done (safe regardless of whether the PLC change is ever deployed):

- `find_device/plc/devices.py` — `WallRelay._var_state` now reads
  `gvlDALI.bRelay{channel-1}`, the real, currently-live readback variable.
  Relay **status** (on/off shown in the app) is correct today, independent
  of this proposal.
- `WallRelay._var_cmd` / `_var_cmd_set` point at the proposed
  `gvlDALI.bPyRelayCmd{N}` / `bPyRelaySet{N}` variables. `set_state()`
  writes cmd, pulses set true→false (50ms), matching the DALI pattern
  already in `DaliChannel.set_brightness()`.

What happens right now if a user taps a relay toggle in the app: the write
call will fail with pyads `symbol not found (1808)` — same failure mode as
before this proposal, not a regression. It's caught by `ADSClient.write()`
and surfaces as a `ConnectionError` / 503 to the API caller, same as any
other unreachable-PLC condition already handled.

## Once the TwinCAT side is deployed

Nothing else needs to change in Django — `WallRelay.set_state()` will
start working the moment `bPyRelayCmd0-3` / `bPyRelaySet0-3` exist on the
real PLC. Re-verify with:

```python
from find_device.models import Apartment
from find_device.plc.registry import DeviceRegistry
apt16 = Apartment.objects.get(name="Apartment 16")
reg = DeviceRegistry.for_apartment(apt16.pk)
reg.relay(1).set_state(True)   # Light 1 relay
print(reg.relay(1).read_state())
```
