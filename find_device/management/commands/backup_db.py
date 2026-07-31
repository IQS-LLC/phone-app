"""
backup_db — pg_dump the production database to a timestamped, compressed
file and prune backups older than BACKUP_RETENTION_DAYS.

Run manually: python manage.py backup_db
Run automatically: find_device.tasks.backup_database, nightly via Celery
Beat (see PLC_Project.settings.CELERY_BEAT_SCHEDULE).

Uses pg_dump's custom format (-Fc) — compressed, and restorable with
pg_restore against a specific table/schema, not just "restore everything
or nothing" like a plain .sql dump.

Restore: pg_restore -h <host> -U <user> -d <dbname> --clean --if-exists <file>
"""
from __future__ import annotations

import logging
import os
import subprocess
import time
from datetime import datetime, timedelta, timezone as dt_timezone
from pathlib import Path

from django.core.management.base import BaseCommand
from django.db import connection

logger = logging.getLogger("lumina.backup")


class Command(BaseCommand):
    help = "Dump the database to BACKUP_DIR and prune backups older than BACKUP_RETENTION_DAYS."

    def add_arguments(self, parser):
        parser.add_argument(
            "--dir", default=os.getenv("BACKUP_DIR", "/app/backups"),
            help="Directory to write the backup file into (default: BACKUP_DIR env or /app/backups).",
        )
        parser.add_argument(
            "--retention-days", type=int, default=int(os.getenv("BACKUP_RETENTION_DAYS", "14")),
            help="Delete backup files older than this many days (default: BACKUP_RETENTION_DAYS env or 14).",
        )

    def handle(self, *args, **options):
        db = connection.settings_dict
        if "postgresql" not in db["ENGINE"]:
            self.stdout.write(self.style.WARNING(
                f"backup_db: skipped — DB engine is {db['ENGINE']!r}, not PostgreSQL "
                "(pg_dump only applies to the Postgres-backed dev/prod stacks)."
            ))
            return

        backup_dir = Path(options["dir"])
        backup_dir.mkdir(parents=True, exist_ok=True)

        stamp    = datetime.now(dt_timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        out_file = backup_dir / f"lugh_db_{stamp}.dump"

        env = os.environ.copy()
        if db["PASSWORD"]:
            env["PGPASSWORD"] = db["PASSWORD"]

        cmd = [
            "pg_dump", "-Fc",
            "-h", db["HOST"] or "localhost",
            "-p", str(db["PORT"] or "5432"),
            "-U", db["USER"],
            "-f", str(out_file),
            db["NAME"],
        ]

        t_start = time.monotonic()
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
        elapsed_s = time.monotonic() - t_start

        if result.returncode != 0:
            out_file.unlink(missing_ok=True)
            logger.error("backup_db: pg_dump failed (%.1fs): %s", elapsed_s, result.stderr.strip())
            self.stderr.write(self.style.ERROR(f"backup_db: pg_dump failed: {result.stderr.strip()}"))
            raise RuntimeError(f"pg_dump exited {result.returncode}: {result.stderr.strip()}")

        size_mb = out_file.stat().st_size / (1024 * 1024)
        logger.info(
            "backup_db: wrote %s (%.1f MB, %.1fs)", out_file.name, size_mb, elapsed_s,
        )
        self.stdout.write(self.style.SUCCESS(
            f"backup_db: wrote {out_file.name} ({size_mb:.1f} MB, {elapsed_s:.1f}s)"
        ))

        retention_days = options["retention_days"]
        cutoff = datetime.now(dt_timezone.utc) - timedelta(days=retention_days)
        removed = 0
        for f in backup_dir.glob("lugh_db_*.dump"):
            if datetime.fromtimestamp(f.stat().st_mtime, tz=dt_timezone.utc) < cutoff:
                f.unlink()
                removed += 1
        if removed:
            logger.info("backup_db: pruned %d backup(s) older than %d day(s)", removed, retention_days)
            self.stdout.write(self.style.SUCCESS(
                f"backup_db: pruned {removed} backup(s) older than {retention_days} day(s)"
            ))
