from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('find_device', '0017_scanrun_one_running_scan_per_apartment'),
    ]

    operations = [
        migrations.AlterField(
            model_name='discoveredcapability',
            name='test_status',
            field=models.CharField(choices=[
                ('not_tested', 'Not tested'),
                ('observed', 'Discovered — not actively tested'),
                ('tested_ok', 'Tested — passed'),
                ('tested_failed', 'Tested — failed'),
                ('unavailable', 'Unavailable — PLC disconnected during test'),
            ], default='not_tested', max_length=15),
        ),
    ]
