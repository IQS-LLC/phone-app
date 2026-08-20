"""
Adds BuildingMembership — the Building Owner tier above ApartmentMembership.

Also backfills Apartment.building for the two existing apartments: both
are confirmed to be the same physical building, so both get the same
placeholder name ("Main Building") purely so a future BuildingMembership
row has something real to match against. Rename it via Django admin (or a
future apartment-management endpoint) once there's a real building name to
use — nothing else depends on the literal string, only that both
apartments in the same building share the same value.
"""
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


def set_shared_building_name(apps, schema_editor):
    Apartment = apps.get_model('find_device', 'Apartment')
    Apartment.objects.filter(building='').update(building='Main Building')


def set_shared_building_name_reverse(apps, schema_editor):
    Apartment = apps.get_model('find_device', 'Apartment')
    Apartment.objects.filter(building='Main Building').update(building='')


class Migration(migrations.Migration):

    dependencies = [
        ('find_device', '0009_plcdevice_down_since'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='BuildingMembership',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('building', models.CharField(max_length=200)),
                ('role', models.CharField(choices=[('owner', 'Building Owner')], default='owner', max_length=12)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='building_memberships', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'unique_together': {('user', 'building')},
            },
        ),
        migrations.RunPython(set_shared_building_name, set_shared_building_name_reverse),
    ]
