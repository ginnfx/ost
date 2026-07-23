"""Application bootstrap: build the QApplication, apply the dark theme, ensure
the database exists, and show the main window."""

from __future__ import annotations

import logging
import os
import sys

from PySide6.QtWidgets import QApplication

from ost_tracker import APP_NAME
from ost_tracker.db.connection import get_db
from ost_tracker.ui.theme import apply_theme


def build_app() -> QApplication:
    app = QApplication.instance() or QApplication(sys.argv)
    app.setApplicationName(APP_NAME)
    app.setApplicationDisplayName(APP_NAME)
    app.setOrganizationName("OST Tracker")
    # Playback resolution logs its search fan-out and timings here, so the
    # pipeline's parallelism is observable on stderr rather than assumed.
    logging.getLogger("ost_tracker.playback").setLevel(logging.INFO)
    if not logging.getLogger().handlers:
        logging.basicConfig(
            level=logging.WARNING,
            format="%(asctime)s %(name)s: %(message)s",
            datefmt="%H:%M:%S",
        )
    apply_theme(app)
    return app


def run() -> int:
    app = build_app()
    get_db()  # create/migrate the DB up front

    # One-time data migrations (e.g. backfilling self-ratings for OSTs added
    # before that feature existed). Guarded so each runs once per database.
    from ost_tracker.db import migrations
    migrations.run_pending()

    # Imported here so the DB and theme are ready before any screen is built.
    from ost_tracker.ui.main_window import MainWindow

    window = MainWindow()
    window.show()
    window.raise_()
    window.activateWindow()

    # Self-test hook: used to verify a packaged .app boots (loads Qt, the theme,
    # qtawesome fonts, the bundled schema, and every screen) without entering
    # the blocking event loop or popping a window.
    if os.environ.get("OST_TRACKER_SELFTEST") == "1":
        for _ in range(5):
            app.processEvents()
        return 0

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(run())
