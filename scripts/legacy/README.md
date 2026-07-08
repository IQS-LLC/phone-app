# Legacy scripts

These three launchers (`start_lan.bat`, `start_local.bat`, `start_backend_only.ps1`)
are superseded by `start_project.ps1` in the repo root, which now correctly:

- binds Django to `0.0.0.0` (works for emulator, LAN, and custom-IP modes from one process)
- never rewrites `lib/main.dart` (these scripts did, destructively, on every launch)
- bootstraps a working dev login automatically (`manage.py bootstrap_dev_user`)
- doesn't require a `.venv` that may not exist

Kept here for reference rather than deleted outright, in case anything still
shells out to them. If nothing has referenced them after a few months, they
can be deleted for good.
