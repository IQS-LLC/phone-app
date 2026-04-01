from django.urls import path
from . import views

urlpatterns = [
    path('', views.health),
    path('brightness/', views.set_brightness),
    path('fade/', views.set_fade),
    path('state/', views.get_state),
    path('init/', views.force_init),
]