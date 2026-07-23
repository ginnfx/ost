"""App settings dialog.

Optional API credentials, all stored in ``config.json`` under Application
Support — never hardcoded and never in the app bundle:

* **Bing Search API key** — unlocks the cover picker's broad-web image tier
  AND the playback pipeline's web-search fallback. Blank disables both;
  everything else still works.
* **Spotify client ID / secret** — Client Credentials flow, metadata search
  only (no user auth, no Spotify playback): refines the playback pipeline's
  YouTube search with canonical artist/title. Blank skips the Spotify tier.
"""

from __future__ import annotations

from PySide6.QtWidgets import (
    QDialogButtonBox,
    QDialog,
    QFormLayout,
    QLabel,
    QLineEdit,
    QVBoxLayout,
    QWidget,
)

from ost_tracker import config
from ost_tracker.ui import theme


def _secret_field(initial: str, placeholder: str) -> QLineEdit:
    field = QLineEdit(initial)
    field.setPlaceholderText(placeholder)
    field.setEchoMode(QLineEdit.Password)
    field.setMinimumWidth(300)
    return field


class SettingsDialog(QDialog):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Settings")
        self.setMinimumWidth(480)

        root = QVBoxLayout(self)
        form = QFormLayout()
        form.setSpacing(10)

        self.bing_edit = _secret_field(
            config.get_bing_api_key() or "",
            "Optional — Bing image tier + playback link fallback",
        )
        form.addRow("Bing Search API key", self.bing_edit)

        spotify_id, spotify_secret = config.get_spotify_credentials() or ("", "")
        self.spotify_id_edit = _secret_field(
            spotify_id, "Optional — refines playback search via Spotify metadata"
        )
        form.addRow("Spotify client ID", self.spotify_id_edit)
        self.spotify_secret_edit = _secret_field(spotify_secret, "Optional")
        form.addRow("Spotify client secret", self.spotify_secret_edit)
        root.addLayout(form)

        hint = QLabel(
            "Stored locally in config.json under Application Support — never in the app "
            "bundle. All fields are optional: without them the cover picker still uses "
            "iTunes, MusicBrainz and YouTube, and playback still searches YouTube directly."
        )
        hint.setWordWrap(True)
        hint.setStyleSheet(f"color:{theme.TEXT_DIM}; font-size:11px;")
        root.addWidget(hint)

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

    def _save(self) -> None:
        config.set_bing_api_key(self.bing_edit.text())
        config.set_spotify_credentials(
            self.spotify_id_edit.text(), self.spotify_secret_edit.text()
        )
        self.accept()
