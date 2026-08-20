from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('find_device', '0016_superscan'),
    ]

    operations = [
        migrations.AddConstraint(
            model_name='scanrun',
            constraint=models.UniqueConstraint(
                condition=models.Q(('status', 'running')),
                fields=('apartment',),
                name='one_running_scan_per_apartment',
            ),
        ),
    ]
