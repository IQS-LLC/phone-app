from django.urls import path
from . import views

urlpatterns = [
    path('',                          views.health),
    path('state/',                    views.get_state),
    path('devices/',                  views.get_devices),
    path('dali/all/brightness/',      views.set_dali_brightness_all),
    path('dali/<int:channel>/brightness/', views.set_dali_brightness),
    path('relay/<int:channel>/',      views.set_relay),
]
