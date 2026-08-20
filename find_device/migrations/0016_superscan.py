from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('find_device', '0015_userprofile_fade_durations'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='ScanRun',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('mode', models.CharField(choices=[
                    ('passive', 'Passive — observe only, zero commands sent'),
                    ('quick', 'Quick — passive discovery of existing entities/state'),
                    ('full', 'Full — quick scan + safe capability tests'),
                    ('deep', 'Deep SuperScan — full scan + unknown-symbol correlation'),
                ], max_length=10)),
                ('status', models.CharField(choices=[
                    ('running', 'Running'),
                    ('completed', 'Completed'),
                    ('stopped', 'Stopped by user'),
                    ('failed', 'Failed'),
                ], default='running', max_length=10)),
                ('started_at', models.DateTimeField(auto_now_add=True)),
                ('finished_at', models.DateTimeField(blank=True, null=True)),
                ('cancel_requested', models.BooleanField(default=False)),
                ('progress_current', models.PositiveIntegerField(default=0)),
                ('progress_total', models.PositiveIntegerField(default=0)),
                ('progress_label', models.CharField(blank=True, max_length=200)),
                ('devices_discovered', models.PositiveIntegerField(default=0)),
                ('capabilities_discovered', models.PositiveIntegerField(default=0)),
                ('capabilities_tested', models.PositiveIntegerField(default=0)),
                ('tests_passed', models.PositiveIntegerField(default=0)),
                ('tests_failed', models.PositiveIntegerField(default=0)),
                ('unknown_count', models.PositiveIntegerField(default=0)),
                ('new_since_last', models.PositiveIntegerField(default=0)),
                ('changed_since_last', models.PositiveIntegerField(default=0)),
                ('removed_since_last', models.PositiveIntegerField(default=0)),
                ('error_message', models.TextField(blank=True)),
                ('apartment', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='scan_runs', to='find_device.apartment')),
                ('started_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-started_at'],
            },
        ),
        migrations.CreateModel(
            name='DiscoveredCapability',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('device_type', models.CharField(max_length=30)),
                ('identifier', models.CharField(max_length=100)),
                ('name', models.CharField(blank=True, max_length=150)),
                ('room', models.CharField(blank=True, max_length=100)),
                ('direction', models.CharField(choices=[
                    ('input', 'Input (sensor/switch — read-only)'),
                    ('output', 'Output (controllable)'),
                    ('both', 'Both (read + write)'),
                ], default='output', max_length=10)),
                ('is_known_type', models.BooleanField(default=True)),
                ('raw_var_name', models.CharField(blank=True, max_length=200)),
                ('data_type', models.CharField(blank=True, max_length=40)),
                ('valid_range', models.CharField(blank=True, max_length=100)),
                ('test_status', models.CharField(choices=[
                    ('not_tested', 'Not tested'),
                    ('observed', 'Discovered — not actively tested'),
                    ('tested_ok', 'Tested — passed'),
                    ('tested_failed', 'Tested — failed'),
                ], default='not_tested', max_length=15)),
                ('confidence', models.CharField(default='high', max_length=10)),
                ('physical_effect_confirmed', models.BooleanField(default=False)),
                ('can_safely_test', models.BooleanField(default=True)),
                ('last_value', models.CharField(blank=True, max_length=100)),
                ('last_tested_at', models.DateTimeField(blank=True, null=True)),
                ('first_seen_at', models.DateTimeField(auto_now_add=True)),
                ('still_present', models.BooleanField(default=True)),
                ('notes', models.TextField(blank=True)),
                ('apartment', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='discovered_capabilities', to='find_device.apartment')),
                ('apartment_device', models.ForeignKey(blank=True, help_text='Set when this capability corresponds to an already-modeled ApartmentDevice row.', null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='discovered_capabilities', to='find_device.apartmentdevice')),
                ('last_seen_scan', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='find_device.scanrun')),
            ],
            options={
                'ordering': ['device_type', 'identifier'],
            },
        ),
        migrations.AlterUniqueTogether(
            name='discoveredcapability',
            unique_together={('apartment', 'device_type', 'identifier')},
        ),
        migrations.CreateModel(
            name='CapabilityTestLog',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('timestamp', models.DateTimeField(auto_now_add=True)),
                ('command_sent', models.CharField(blank=True, max_length=100)),
                ('params', models.JSONField(blank=True, default=dict)),
                ('state_before', models.CharField(blank=True, max_length=100)),
                ('state_after', models.CharField(blank=True, max_length=100)),
                ('response', models.CharField(blank=True, max_length=200)),
                ('success', models.BooleanField(default=False)),
                ('latency_ms', models.FloatField(blank=True, null=True)),
                ('error', models.TextField(blank=True)),
                ('capability', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='test_logs', to='find_device.discoveredcapability')),
                ('scan_run', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='test_logs', to='find_device.scanrun')),
            ],
            options={
                'ordering': ['-timestamp'],
            },
        ),
    ]
