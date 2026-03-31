from django.contrib import admin
from django.urls import path, include
from django.http import HttpResponse


def health_check(request):
    return HttpResponse("healthy\n", content_type="text/plain")


urlpatterns = [
    path('admin/', admin.site.urls),
    path('health/', health_check),
    path('plc/', include('find_device.urls')),
]