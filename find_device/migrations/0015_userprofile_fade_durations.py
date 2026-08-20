from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('find_device', '0014_userprofile_show_ventilators_home'),
    ]

    operations = [
        migrations.AddField(
            model_name='userprofile',
            name='dim_duration_ms',
            field=models.PositiveIntegerField(default=800),
        ),
        migrations.AddField(
            model_name='userprofile',
            name='undim_duration_ms',
            field=models.PositiveIntegerField(default=500),
        ),
    ]
