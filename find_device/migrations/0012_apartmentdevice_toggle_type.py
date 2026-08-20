from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('find_device', '0011_automation_rule'),
    ]

    operations = [
        migrations.AlterField(
            model_name='apartmentdevice',
            name='device_type',
            field=models.CharField(max_length=20, choices=[
                ('dali', 'DALI dimmer'),
                ('relay', 'Wall relay'),
                ('switch', 'Switch input'),
                ('curtain', 'Curtain motor'),
                ('appliance', 'Appliance relay'),
                ('door_sensor', 'Door sensor'),
                ('window_sensor', 'Window sensor'),
                ('motion_sensor', 'Motion sensor'),
                ('toggle', 'Named relay/light'),
            ]),
        ),
    ]
