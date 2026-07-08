"""
Data migration: backfill the new multi-tenant model.

1. Every existing PLCDevice (created under the old "one user, one device"
   model) gets its own Apartment + an ApartmentMembership(role=owner) for
   whoever registered it, so existing logins keep working unchanged.

2. Seeds Apartment 16 and Apartment 8 with their real Room/ApartmentDevice
   layout (16 DALI channels, 4 wall relays, 10 switches each), migrated out
   of the old hardcoded APARTMENT_CONFIGS dict in find_device/plc/registry.py.
   These two are intentionally created WITHOUT a PLCDevice or membership —
   nobody has registered the real PLC connection or assigned a resident yet.
   That happens through the installer workflow once it exists.
"""
from django.db import migrations


# Mirrors find_device/plc/registry.py APARTMENT_CONFIGS at the time this
# migration was written. Both apartments share the identical hardware
# layout (28-address DALI bus, 16 channels wired up; 4 KL2809 wall relays).
ROOM_DALI_LAYOUT = [
    (1,  'Light 1',  'Living Room'), (2,  'Light 2',  'Living Room'),
    (3,  'Light 3',  'Living Room'), (4,  'Light 4',  'Living Room'),
    (5,  'Light 5',  'Dining Room'), (6,  'Light 6',  'Dining Room'),
    (7,  'Light 7',  'Dining Room'), (8,  'Light 8',  'Dining Room'),
    (9,  'Light 9',  'Bedroom 1'),   (10, 'Light 10', 'Bedroom 1'),
    (11, 'Light 11', 'Bedroom 2'),   (12, 'Light 12', 'Bedroom 2'),
    (13, 'Light 13', 'Kitchen'),     (14, 'Light 14', 'Kitchen'),
    (15, 'Light 15', 'Hallway'),     (16, 'Light 16', 'Hallway'),
]
RELAY_LAYOUT = [
    (1, 'Wall Light 1', 'Living Room'), (2, 'Wall Light 2', 'Living Room'),
    (3, 'Wall Light 3', 'Hallway'),     (4, 'Wall Light 4', 'Hallway'),
]
SWITCH_LAYOUT = [
    (1,  'Living Room Main', 'Living Room'), (2,  'Dining Room Main', 'Dining Room'),
    (3,  'Bedroom 1 Main',   'Bedroom 1'),   (4,  'Bedroom 2 Main',   'Bedroom 2'),
    (5,  'Kitchen Main',     'Kitchen'),     (6,  'Hallway Main',     'Hallway'),
    (7,  'Wall Light 1 SW',  'Living Room'), (8,  'Wall Light 2 SW',  'Living Room'),
    (9,  'Wall Light 3 SW',  'Hallway'),     (10, 'Wall Light 4 SW',  'Hallway'),
]


def _seed_apartment(apps, name):
    Apartment       = apps.get_model('find_device', 'Apartment')
    Room            = apps.get_model('find_device', 'Room')
    ApartmentDevice = apps.get_model('find_device', 'ApartmentDevice')

    apt = Apartment.objects.create(name=name)
    rooms = {}

    def room_for(room_name, order):
        if room_name not in rooms:
            rooms[room_name] = Room.objects.create(
                apartment=apt, name=room_name, sort_order=order,
            )
        return rooms[room_name]

    room_order = {
        'Living Room': 0, 'Dining Room': 1, 'Bedroom 1': 2,
        'Bedroom 2': 3, 'Kitchen': 4, 'Hallway': 5,
    }

    for ch, dev_name, room_name in ROOM_DALI_LAYOUT:
        ApartmentDevice.objects.create(
            apartment=apt, room=room_for(room_name, room_order[room_name]),
            device_type='dali', channel_or_index=ch, name=dev_name,
            sort_order=ch,
        )
    for ch, dev_name, room_name in RELAY_LAYOUT:
        ApartmentDevice.objects.create(
            apartment=apt, room=room_for(room_name, room_order[room_name]),
            device_type='relay', channel_or_index=ch, name=dev_name,
            sort_order=ch,
        )
    for idx, dev_name, room_name in SWITCH_LAYOUT:
        ApartmentDevice.objects.create(
            apartment=apt, room=room_for(room_name, room_order[room_name]),
            device_type='switch', channel_or_index=idx, name=dev_name,
            sort_order=idx,
        )


def backfill(apps, schema_editor):
    Apartment           = apps.get_model('find_device', 'Apartment')
    PLCDevice            = apps.get_model('find_device', 'PLCDevice')
    ApartmentMembership  = apps.get_model('find_device', 'ApartmentMembership')

    for device in PLCDevice.objects.filter(apartment__isnull=True):
        apt = Apartment.objects.create(name=device.name or f"Apartment (device {device.pk})")
        device.apartment = apt
        device.save(update_fields=['apartment'])
        ApartmentMembership.objects.create(
            user=device.owner, apartment=apt,
            role='owner', is_default=device.is_default,
        )

    if not Apartment.objects.filter(name='Apartment 16').exists():
        _seed_apartment(apps, 'Apartment 16')
    if not Apartment.objects.filter(name='Apartment 8').exists():
        _seed_apartment(apps, 'Apartment 8')


def backfill_reverse(apps, schema_editor):
    # Irreversible by design — backing out would silently delete apartment
    # data. If you need to roll back, restore from a DB backup instead.
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('find_device', '0002_apartment_alter_plcdevice_is_default_and_more'),
    ]

    operations = [
        migrations.RunPython(backfill, backfill_reverse),
    ]
