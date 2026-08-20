from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('find_device', '0013_apartmentdevice_named_switch_type'),
    ]

    operations = [
        migrations.AddField(
            model_name='userprofile',
            name='show_ventilators_home',
            field=models.BooleanField(default=True),
        ),
    ]
