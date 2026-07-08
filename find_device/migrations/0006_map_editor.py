from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ("find_device", "0005_seed_roles_permissions"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name="MapLayout",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("canvas_width",         models.FloatField(default=2000)),
                ("canvas_height",        models.FloatField(default=1500)),
                ("background_url",       models.CharField(blank=True, max_length=500)),
                ("background_x",         models.FloatField(default=0)),
                ("background_y",         models.FloatField(default=0)),
                ("background_width",     models.FloatField(default=2000)),
                ("background_height",    models.FloatField(default=1500)),
                ("background_rotation",  models.FloatField(default=0)),
                ("background_opacity",   models.FloatField(default=0.25)),
                ("background_locked",    models.BooleanField(default=True)),
                ("background_visible",   models.BooleanField(default=True)),
                ("is_published",  models.BooleanField(default=False)),
                ("published_at",  models.DateTimeField(blank=True, null=True)),
                ("created_at",    models.DateTimeField(auto_now_add=True)),
                ("updated_at",    models.DateTimeField(auto_now=True)),
                ("apartment", models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="map_layout",
                    to="find_device.apartment",
                )),
                ("created_by", models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name="created_map_layouts",
                    to=settings.AUTH_USER_MODEL,
                )),
            ],
            options={"verbose_name": "Map Layout"},
        ),
        migrations.CreateModel(
            name="MapLayer",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name",       models.CharField(max_length=100)),
                ("layer_type", models.CharField(
                    choices=[
                        ("background", "Background"), ("walls", "Walls"),
                        ("furniture", "Furniture"),   ("electrical", "Electrical"),
                        ("lighting", "Lighting"),     ("sensors", "Sensors"),
                        ("security", "Security"),     ("hvac", "HVAC"),
                        ("energy", "Energy"),         ("networking", "Networking"),
                        ("labels", "Labels"),         ("annotations", "Annotations"),
                    ],
                    default="labels", max_length=20,
                )),
                ("visible",    models.BooleanField(default=True)),
                ("locked",     models.BooleanField(default=False)),
                ("sort_order", models.PositiveIntegerField(default=0)),
                ("layout", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="layers",
                    to="find_device.maplayout",
                )),
            ],
            options={"ordering": ["sort_order", "id"]},
        ),
        migrations.CreateModel(
            name="CanvasObject",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("object_type", models.CharField(
                    choices=[
                        ("room", "Room"), ("device", "Device"),
                        ("label", "Label"), ("wall", "Wall"),
                    ],
                    default="device", max_length=10,
                )),
                ("device_type", models.CharField(
                    blank=True,
                    choices=[
                        ("ceiling_light", "Ceiling Light"),   ("pendant_light", "Pendant Light"),
                        ("led_strip", "LED Strip"),           ("relay_light", "Relay Light"),
                        ("curtain", "Curtain"),               ("blind", "Blind"),
                        ("window", "Window"),                 ("door", "Door"),
                        ("door_sensor", "Door Sensor"),       ("window_sensor", "Window Sensor"),
                        ("presence_sensor", "Presence Sensor"), ("smoke_detector", "Smoke Detector"),
                        ("heat_detector", "Heat Detector"),   ("leak_sensor", "Leak Sensor"),
                        ("hvac", "HVAC"),                     ("thermostat", "Thermostat"),
                        ("temperature_sensor", "Temperature Sensor"), ("humidity_sensor", "Humidity Sensor"),
                        ("power_outlet", "Power Outlet"),     ("usb_outlet", "USB Outlet"),
                        ("tv_outlet", "TV Outlet"),           ("rj45_outlet", "RJ45 Outlet"),
                        ("garage_door", "Garage Door"),       ("gate", "Gate"),
                        ("camera", "Camera"),                 ("doorbird", "DoorBird"),
                        ("intercom", "Intercom"),             ("speaker", "Speaker"),
                        ("microphone", "Microphone"),         ("alarm", "Alarm"),
                        ("weather_station", "Weather Station"), ("solar", "Solar"),
                        ("battery", "Battery"),               ("ev_charger", "EV Charger"),
                        ("garden", "Garden"),                 ("pool", "Pool"),
                        ("custom", "Custom"),
                    ],
                    max_length=30,
                )),
                ("name",          models.CharField(max_length=200)),
                ("x",             models.FloatField(default=100)),
                ("y",             models.FloatField(default=100)),
                ("width",         models.FloatField(default=48)),
                ("height",        models.FloatField(default=48)),
                ("rotation",      models.FloatField(default=0)),
                ("plc_variable",  models.CharField(blank=True, max_length=255)),
                ("color",         models.CharField(blank=True, max_length=20)),
                ("label_visible", models.BooleanField(default=True)),
                ("group_id",      models.CharField(blank=True, max_length=50)),
                ("properties",    models.JSONField(blank=True, default=dict)),
                ("sort_order",    models.PositiveIntegerField(default=0)),
                ("created_at",    models.DateTimeField(auto_now_add=True)),
                ("updated_at",    models.DateTimeField(auto_now=True)),
                ("apartment_device", models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name="canvas_objects",
                    to="find_device.apartmentdevice",
                )),
                ("layer", models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name="objects",
                    to="find_device.maplayer",
                )),
                ("layout", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="objects",
                    to="find_device.maplayout",
                )),
                ("room", models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name="canvas_objects",
                    to="find_device.room",
                )),
            ],
            options={"ordering": ["sort_order", "id"]},
        ),
        migrations.CreateModel(
            name="MapVersion",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("version_number", models.PositiveIntegerField()),
                ("snapshot",       models.JSONField()),
                ("created_at",     models.DateTimeField(auto_now_add=True)),
                ("description",    models.CharField(blank=True, max_length=255)),
                ("is_published",   models.BooleanField(default=False)),
                ("created_by", models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    to=settings.AUTH_USER_MODEL,
                )),
                ("layout", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="versions",
                    to="find_device.maplayout",
                )),
            ],
            options={"ordering": ["-version_number"], "unique_together": {("layout", "version_number")}},
        ),
    ]
