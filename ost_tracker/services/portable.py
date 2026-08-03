"""Portable competition bundle.

Export/import of a whole competition (``ost.db`` + ``covers/``) as a zip so a
competition can move between machines or platforms — the supplement for the
multi-platform split (each platform keeps its own data dir; the bundle is how
you carry a competition across).

Import is staged into ``<data>/.import`` and applied on the next launch
(``apply_staged_import`` runs before the DB is opened), so the running app
never fights the open connection for the file.
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import tempfile
import zipfile
from pathlib import Path

from .. import config


def export_bundle() -> Path:
    """Zip a consistent snapshot (sqlite backup API) of ost.db + covers/."""
    db = config.database_path()
    if not db.exists():
        raise FileNotFoundError("no competition data yet")

    fd, tmp = tempfile.mkstemp(prefix="ost-portable-", suffix=".zip")
    os.close(fd)
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zf:
            with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
                backup_path = Path(f.name)
            try:
                src = sqlite3.connect(db)
                dst = sqlite3.connect(backup_path)
                try:
                    with dst:
                        src.backup(dst)
                finally:
                    src.close()
                    dst.close()
                zf.write(backup_path, "ost.db")
            finally:
                backup_path.unlink(missing_ok=True)

            covers = config.covers_dir()
            if covers.is_dir():
                for cover in sorted(covers.iterdir()):
                    if cover.is_file():
                        zf.write(cover, f"covers/{cover.name}")
    except Exception:
        Path(tmp).unlink(missing_ok=True)
        raise
    return Path(tmp)


def stage_import(bundle: Path) -> None:
    """Validate a portable zip and stage it under ``<data>/.import``.

    The new files are applied by ``apply_staged_import()`` on next launch.
    """
    if not bundle.is_file():
        raise FileNotFoundError("bundle not found")

    with zipfile.ZipFile(bundle) as zf:
        names = zf.namelist()
        if "ost.db" not in names:
            raise ValueError("bundle has no ost.db")

        base = config.app_support_dir()
        staging = base / ".import"
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir(parents=True)

        # zip-slip guard: every member must resolve inside the app dir.
        base_resolved = base.resolve()
        for name in names:
            target = (staging / name).resolve()
            if not str(target).startswith(str(base_resolved)):
                shutil.rmtree(staging)
                raise ValueError(f"unsafe member in bundle: {name}")

        zf.extractall(staging)


def apply_staged_import() -> bool:
    """Swap a staged import into place. Called at startup, before the DB
    opens. Returns True if an import was applied."""
    base = config.app_support_dir()
    staging = base / ".import"
    if not (staging / "ost.db").is_file():
        return False

    db = config.database_path()
    if db.exists():
        os.replace(db, db.with_name("ost.db.prior"))
    os.replace(staging / "ost.db", db)

    covers = config.covers_dir()
    covers.mkdir(parents=True, exist_ok=True)
    staged_covers = staging / "covers"
    if staged_covers.is_dir():
        for member in staged_covers.iterdir():
            if member.is_file():
                os.replace(member, covers / member.name)

    shutil.rmtree(staging, ignore_errors=True)
    return True
